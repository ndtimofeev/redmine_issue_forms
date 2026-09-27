# Loads Redmine's own test helper (fixtures, Redmine::ControllerTest...).
# Run from the Redmine root:
#   bin/rails redmine:plugins:test NAME=redmine_issue_forms
require File.expand_path('../../../test/test_helper', __dir__)

module RedmineIssueForms
  # Makes issue 1 (project 1 "ecookbook", tracker 1 "Bug") a form issue:
  # Textile formatting, tracker 1 configured, module enabled.
  module TestSetup
    def enable_issue_forms(project_id: 1, tracker_ids: ['1'])
      @saved_text_formatting = Setting.text_formatting
      @saved_plugin_settings = Setting.plugin_redmine_issue_forms
      Setting.text_formatting = 'textile'
      Setting.plugin_redmine_issue_forms = { 'tracker_ids' => tracker_ids }
      Project.find(project_id).enable_module!(RedmineIssueForms::PROJECT_MODULE)
    end

    def restore_settings
      Setting.text_formatting = @saved_text_formatting if @saved_text_formatting
      Setting.plugin_redmine_issue_forms = @saved_plugin_settings || {}
    end

    def form_issue(description)
      issue = Issue.find(1)
      issue.update_columns(description: description)
      issue.journals.update_all(notes: '')
      issue
    end

    def add_note(issue, notes, user: User.find(2), private_notes: false)
      Journal.create!(journalized: issue, user: user, notes: notes, private_notes: private_notes)
    end
  end
end
