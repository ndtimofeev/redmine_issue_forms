# Saves what was typed into a form issue's description as one ordinary
# comment on the issue. From Redmine's point of view filling a form *is*
# adding a note: the same permission (add_issue_notes), the same journal,
# the same e-mail notification, the same history entry - and undoing it is
# editing or deleting that note, with Redmine's own permissions for that.
class IssueFormValuesController < ApplicationController
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
        @form, form_params[:values],
        edited_ids: form_params[:edited], seen_journal_id: form_params[:seen]
      )

      if submission.any?
        @issue.init_journal(User.current, submission.note)
        saved = @issue.save
        raise ActiveRecord::Rollback unless saved
      end
    end

    flash_result(submission, saved)
    redirect_to issue_path(@issue, anchor: submission.anchor || 'issue_description_wiki')
  end

  private

  def form_params
    @form_params ||= begin
      raw = params[:issue_form]
      raw = raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : {}
      {
        # Only plain strings: anything else (nested hashes, arrays) is not
        # something our form could have produced.
        values: raw['values'].is_a?(Hash) ? raw['values'].select { |_, v| v.is_a?(String) } : {},
        edited: Array(raw['edited']).grep(String),
        seen: raw['seen'].to_s
      }
    end
  end

  # Flash messages are rendered with html_safe by core
  # (ApplicationHelper#render_flash_messages), and they contain keys and
  # table names written by whoever edited the description, so every
  # message built here is escaped explicitly.
  def flash_result(submission, saved)
    unless saved
      flash[:error] = ERB::Util.h(@issue.errors.full_messages.join(', '))
      return
    end

    flash[:notice] = l(submission.any? ? :notice_issue_forms_saved : :notice_issue_forms_nothing_to_save)

    warnings = []
    if submission.conflicts.any?
      labels = submission.conflicts.map { |target| @form.target_label(target) }
      warnings << l(:warning_issue_forms_conflict, fields: labels.join(', '))
    end
    warnings << l(:warning_issue_forms_stale) if submission.stale.any?
    if submission.full_tables.any?
      warnings << l(:warning_issue_forms_table_full, tables: submission.full_tables.map(&:name).join(', '),
                                                     count: RedmineIssueForms::MAX_TABLE_ROWS)
    end
    flash[:warning] = warnings.map { |warning| ERB::Util.h(warning) }.join('<br>') if warnings.any?
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
