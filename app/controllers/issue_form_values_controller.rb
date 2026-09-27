# Saves what was typed into a form issue's description as one ordinary
# comment on the issue. From Redmine's point of view filling a form *is*
# adding a note: the same permission (add_issue_notes), the same journal,
# the same e-mail notification, the same history entry - and undoing it is
# editing or deleting that note, with Redmine's own permissions for that.
class IssueFormValuesController < ApplicationController
  # What the pencil and Cancel may name: an HTML id made by Keys.
  FIELD_ID = /\Aifv-\h{16}\z/

  # The flash lives in Redmine's session cookie, which can't grow past
  # 4 KB, so what is repeated back is kept short.
  FLASH_ITEMS = 10
  FLASH_VALUE_LENGTH = 60

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
      fields = submission.conflicts.map do |target|
        l(:text_issue_forms_typed, field: @form.target_label(target), value: quoted(submission.typed_value(target.id)))
      end
      warnings << l(:warning_issue_forms_conflict, fields: short_list(fields))
    end
    if submission.stale.any?
      values = submission.stale.map { |id| quoted(submission.typed_value(id)) }
      warnings << l(:warning_issue_forms_stale, values: short_list(values))
    end
    submission.full_tables.each do |table|
      values = submission.rejected_row(table).map { |value| quoted(value) }
      warnings << l(:warning_issue_forms_table_full, table: table.name, values: short_list(values))
    end

    if submission.any?
      flash[:notice] = l(:notice_issue_forms_saved)
    elsif warnings.empty? && !form_params[:open] && !form_params[:cancel]
      # The pencil and Cancel with nothing typed elsewhere just open or
      # close a value: nothing to report.
      flash[:notice] = l(:notice_issue_forms_nothing_to_save)
    end
    flash[:warning] = warnings.map { |warning| ERB::Util.h(warning) }.join('<br>') if warnings.any?
  end

  def quoted(value)
    l(:text_issue_forms_quoted, value: value.to_s.truncate(FLASH_VALUE_LENGTH))
  end

  def short_list(items)
    list = items.first(FLASH_ITEMS).map { |item| item.truncate(FLASH_VALUE_LENGTH * 2) }
    list << '...' if items.size > FLASH_ITEMS
    list.join(', ')
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
