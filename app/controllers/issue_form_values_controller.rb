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
  # values of FLASH_VALUE_LENGTH characters, and the whole warning within
  # FLASH_BYTES bytes once escaped (bytes: a Cyrillic letter takes two),
  # which leaves room for the rest of the session.
  FLASH_ITEMS = 10
  FLASH_VALUE_LENGTH = 60
  FLASH_BYTES = 1000

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
      fields = submission.conflicts.map { |target| rejected(submission, target.id, @form.target_label(target)) }
      warnings << l(:warning_issue_forms_conflict, fields: short_list(fields))
    end
    if submission.stale.any?
      values = submission.stale.map { |id| rejected(submission, id) }
      warnings << l(:warning_issue_forms_stale, values: short_list(values))
    end
    if submission.full_tables.any?
      values = submission.full_tables.flat_map { |table| submission.rejected_row(table) }.map { |value| quoted(value) }
      warnings << l(:warning_issue_forms_table_full, tables: submission.full_tables.map(&:name).join(', '),
                                                     values: short_list(values))
    end

    if submission.any?
      flash[:notice] = l(:notice_issue_forms_saved)
    elsif warnings.empty? && !form_params[:open] && !form_params[:cancel]
      # The pencil and Cancel with nothing typed elsewhere just open or
      # close a value: nothing to report.
      flash[:notice] = l(:notice_issue_forms_nothing_to_save)
    end
    flash[:warning] = fit_in_flash(warnings) if warnings.any?
  end

  # How a value that wasn't saved is repeated back: "Owner (you typed
  # "Ann")", "Owner (you cleared it)" - or, for a field that is gone and
  # has no name any more, just "Ann" or "clearing "Bob"".
  def rejected(submission, id, label = nil)
    typed = submission.typed_value(id)
    original = submission.original_value(id)
    if typed.empty? && original.present?
      label ? l(:text_issue_forms_cleared, field: label.truncate(FLASH_VALUE_LENGTH)) : l(:text_issue_forms_cleared_value, value: quoted(original))
    else
      label ? l(:text_issue_forms_typed, field: label.truncate(FLASH_VALUE_LENGTH), value: quoted(typed)) : quoted(typed)
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

  # The warnings, escaped and joined, in at most FLASH_BYTES bytes: each
  # gets an equal share and is cut at its end, where the lists are.
  def fit_in_flash(warnings)
    share = FLASH_BYTES / warnings.size
    warnings.map { |warning| escape_within(warning, share) }.join('<br>')
  end

  # +text+ escaped, cut short - before escaping, so no entity is ever cut
  # in half - until it takes at most +bytes+ bytes.
  def escape_within(text, bytes)
    escaped = ERB::Util.h(text)
    length = text.length
    while escaped.bytesize > bytes && length > 3
      length = [length - 1, length * bytes / escaped.bytesize].min
      escaped = ERB::Util.h(text.truncate(length, omission: '...'))
    end
    escaped
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
