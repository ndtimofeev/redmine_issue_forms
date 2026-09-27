# Saves what was typed into a form issue's description as one ordinary
# comment on the issue. From Redmine's point of view filling a form *is*
# adding a note: the same permission (add_issue_notes), the same journal,
# the same e-mail notification, the same history entry - and undoing it is
# editing or deleting that note, with Redmine's own permissions for that.
class IssueFormValuesController < ApplicationController
  # What the pencil and Cancel may name: an HTML id made by Keys.
  FIELD_ID = /\Aifv-\h{16}\z/

  # The flash lives in Redmine's session cookie, and a cookie over 4 KB
  # fails the response with CookieOverflow - after the comment has been
  # saved. So what is repeated back is kept short: at most FLASH_ITEMS
  # values of FLASH_VALUE_LENGTH characters, table and column names of
  # FLASH_NAME_LENGTH, and the whole warning within the room the cookie
  # has left (#flash_room), FLASH_BYTES at most.
  FLASH_ITEMS = 10
  FLASH_VALUE_LENGTH = 60
  FLASH_NAME_LENGTH = 30
  FLASH_BYTES = 1000
  # Cookie bytes per byte of flash text: Redmine 6 (Rails 7.2) encrypts the
  # session and base64-encodes it twice, 16/9.
  COOKIE_GROWTH = 1.8
  # What else the session gains in this request, in cookie bytes: the
  # flash's own structure, the notice, core's timestamps.
  SESSION_SLACK = 400

  before_action :find_form_issue
  before_action :authorize_form

  def create
    submission = nil
    saved = true

    Issue.transaction do
      # Row lock for the rest of the transaction: two people saving at the
      # same moment are serialized, so the second one builds its comment
      # from a Form that already includes the first one's values. This is
      # what makes the conflict check and the choice of a new row's index
      # in Submission safe. lock! also reloads the issue.
      @issue.lock!

      @form = RedmineIssueForms::Form.for_issue(@issue)
      submission = RedmineIssueForms::Submission.new(
        @form, form_params[:values].except(form_params[:cancel]),
        originals: form_params[:originals], layouts: form_params[:layouts]
      )

      if submission.any?
        @issue.init_journal(User.current, submission.note)
        saved = @issue.save
        raise ActiveRecord::Rollback unless saved
      end
    end

    flash_result(submission, saved)
    redirect_to redirect_target(submission, saved)
  end

  private

  # Every button of the form submits it (see Renderer#wrap_in_form); two
  # of them also say where to go next:
  # * the pencil (issue_form[open]=ID) - back to the issue with that value
  #   opened for editing;
  # * Cancel (issue_form[cancel]=ID) - the value opened for editing is
  #   left out of what is saved (see #create), and the page shows it
  #   closed again.
  # Anything typed into other fields is saved either way, so pressing one
  # of them never throws input away.
  def redirect_target(submission, saved)
    if (open_id = form_params[:open]) && saved
      issue_path(@issue, issue_form_edit: open_id, anchor: open_id)
    else
      anchor = submission.anchor || form_params[:cancel] || form_params[:open] || 'issue_description_wiki'
      issue_path(@issue, anchor: anchor)
    end
  end

  def form_params
    @form_params ||= begin
      raw = params[:issue_form]
      raw = raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : {}
      {
        # Only plain strings: anything else (nested hashes, arrays) is not
        # something our form could have produced.
        values: string_hash(raw['values']),
        originals: string_hash(raw['original']),
        layouts: string_hash(raw['layouts']),
        open: raw['open'].is_a?(String) && raw['open'].match?(FIELD_ID) ? raw['open'] : nil,
        cancel: raw['cancel'].is_a?(String) && raw['cancel'].match?(FIELD_ID) ? raw['cancel'] : nil
      }
    end
  end

  def string_hash(value)
    value.is_a?(Hash) ? value.select { |_, v| v.is_a?(String) } : {}
  end

  # Flash messages are rendered with html_safe by core
  # (ApplicationHelper#render_flash_messages), and they contain keys and
  # table names written by whoever edited the description, so every
  # message built here is escaped explicitly.
  #
  # Whatever was typed but not saved is repeated in the warning, so
  # nobody has to retype it from memory.
  def flash_result(submission, saved)
    unless saved
      flash[:error] = ERB::Util.h(@issue.errors.full_messages.join(', '))
      return
    end

    warnings = []
    if submission.conflicts.any?
      fields = submission.conflicts.map { |target| rejected(submission, target.id, flash_label(target)) }
      warnings << l(:warning_issue_forms_conflict, fields: short_list(fields))
    end
    if submission.stale.any?
      values = submission.stale.map { |id| rejected(submission, id) }
      warnings << l(:warning_issue_forms_stale, values: short_list(values))
    end
    if submission.full_tables.any?
      values = submission.full_tables.flat_map { |table| submission.rejected_row(table) }.map { |value| quoted(value) }
      tables = submission.full_tables.map { |table| table.name.truncate(FLASH_NAME_LENGTH) }
      warnings << l(:warning_issue_forms_table_full, tables: tables.join(', '), values: short_list(values))
    end

    if submission.any?
      flash[:notice] = l(:notice_issue_forms_saved)
    elsif warnings.empty? && !form_params[:open] && !form_params[:cancel]
      # The pencil and Cancel with nothing typed elsewhere just open or
      # close a value: nothing to report.
      flash[:notice] = l(:notice_issue_forms_nothing_to_save)
    end
    return if warnings.empty?

    warning = fit_in_flash(warnings, flash_room)
    flash[:warning] = warning if warning.present?
  end

  # How a target is named in a warning: "Owner", "Acceptance : Qty : 3".
  # A long table or column name is shortened on its own, so the row
  # number - the one part that tells rejected cells apart - stays.
  def flash_label(target)
    return target.field.key.truncate(FLASH_VALUE_LENGTH) if target.kind == :field

    table = target.table
    [table.name.truncate(FLASH_NAME_LENGTH), table.columns[target.column].truncate(FLASH_NAME_LENGTH), target.row].join(' : ')
  end

  # How a value that wasn't saved is repeated back: "Owner (you typed
  # "Ann")", "Owner (you cleared it)" - or, for a field that is gone and
  # has no name any more, just "Ann" or "clearing "Bob"".
  def rejected(submission, id, label = nil)
    typed = submission.typed_value(id)
    original = submission.original_value(id)
    if typed.empty? && original.present?
      label ? l(:text_issue_forms_cleared, field: label) : l(:text_issue_forms_cleared_value, value: quoted(original))
    else
      label ? l(:text_issue_forms_typed, field: label, value: quoted(typed)) : quoted(typed)
    end
  end

  def quoted(value)
    l(:text_issue_forms_quoted, value: value.to_s.truncate(FLASH_VALUE_LENGTH))
  end

  def short_list(items)
    list = items.first(FLASH_ITEMS)
    list << '...' if items.size > FLASH_ITEMS
    list.join(', ')
  end

  # How much warning text (in #flash_size bytes) the session cookie still
  # has room for. Measured from the cookie the browser sent, because the
  # session already holds whatever core put there: a saved issue query
  # with a long list of ids takes a few KB. With a session store that
  # keeps only an id in the cookie, FLASH_BYTES is the limit.
  def flash_room
    cookie = request.cookies[Rails.application.config.session_options[:key].to_s].to_s
    room = ((ActionDispatch::Cookies::MAX_COOKIE_SIZE - cookie.bytesize - SESSION_SLACK) / COOKIE_GROWTH).floor
    room.clamp(0, FLASH_BYTES)
  end

  # The size +text+ takes in the session: its bytes (a Cyrillic letter
  # takes two) as JSON would encode it, which is more than Redmine 6's
  # Marshal needs ("&" becomes "\u0026") - so the estimate also holds if
  # Redmine ever switches its session cookies to JSON.
  def flash_size(text)
    ActiveSupport::JSON.encode(text).bytesize - 2
  end

  # The warnings, escaped and joined, in at most +bytes+ (see #flash_size).
  # Warnings that fit in an equal share are kept whole, and what they
  # leave is shared by the others, each cut at its end, where the lists
  # are.
  def fit_in_flash(warnings, bytes)
    separator = '<br>'
    budget = bytes - (flash_size(separator) * (warnings.size - 1))
    fitted = []
    order = warnings.each_index.sort_by { |index| flash_size(ERB::Util.h(warnings[index])) }
    order.each_with_index do |index, done|
      fitted[index] = escape_within(warnings[index], budget / (warnings.size - done))
      budget -= flash_size(fitted[index])
    end
    fitted.reject(&:empty?).join(separator)
  end

  # +text+ escaped, or if that takes more than +bytes+ (see #flash_size),
  # the longest start of it that fits with "..." after it - cut before
  # escaping, so no entity is ever cut in half. Empty when not even "..."
  # fits.
  def escape_within(text, bytes)
    escaped = ERB::Util.h(text)
    return escaped if flash_size(escaped) <= bytes

    cut = ->(length) { ERB::Util.h(text.truncate(length, omission: '...')) }
    # truncate(length) keeps length - 3 characters; 3 is just "...".
    low = 3
    high = text.length - 1
    return '' if flash_size(cut.call(low)) > bytes

    while low < high
      middle = (low + high + 1) / 2
      if flash_size(cut.call(middle)) <= bytes
        low = middle
      else
        high = middle - 1
      end
    end
    cut.call(low)
  end

  def find_form_issue
    @issue = Issue.find(params[:id])
    @project = @issue.project
    # 404, not 403, for an issue that isn't a form: this endpoint should
    # look like it doesn't exist for anything else.
    render_404 unless RedmineIssueForms.form_issue?(@issue)
  rescue ActiveRecord::RecordNotFound
    render_404
  end

  # The module's public permission (see init.rb) is checked by the usual
  # #authorize, which also rejects archived projects and a disabled
  # module. Then the real rule: whoever may add notes to this issue may
  # fill its form.
  def authorize_form
    return unless authorize

    deny_access unless @issue.visible? && @issue.notes_addable?
  end
end
