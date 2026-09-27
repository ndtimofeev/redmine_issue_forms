require File.expand_path('../test_helper', __dir__)

# Editing or deleting a comment on the issue page (JournalsController#update
# over Ajax) and the hook that brings the form up to date afterwards.
class RedmineIssueForms::JournalsUpdateTest < Redmine::ControllerTest
  include RedmineIssueForms::TestSetup
  tests JournalsController

  fixtures :projects, :users, :email_addresses, :user_preferences, :roles, :members, :member_roles,
           :issues, :issue_statuses, :trackers, :projects_trackers, :enabled_modules, :enumerations,
           :journals, :journal_details

  def setup
    enable_issue_forms
    @issue = form_issue("* Date: {}\n")
    @request.session[:user_id] = 1
  end

  def teardown
    restore_settings
  end

  def edit_note(journal, notes)
    put :update, params: { id: journal.id, journal: { notes: notes } }, xhr: true
    assert_response :success
  end

  test 'changing a value reloads the form, unless something is typed' do
    edit_note(add_note(@issue, 'Date : 1'), 'Date : 2')
    assert_includes response.body, 'window.location.reload()'
    assert_includes response.body, 'issue-form-comments-changed'
  end

  test 'turning a value into prose or deleting it reloads too' do
    edit_note(add_note(@issue, 'Date : 1'), 'nothing here')
    assert_includes response.body, 'window.location.reload()'

    edit_note(add_note(@issue, 'Date : 1'), '')
    assert_includes response.body, 'window.location.reload()'
  end

  test 'an unrelated comment leaves the page alone' do
    edit_note(add_note(@issue, 'Looks good'), 'Looks good to me')
    assert_not_includes response.body, 'reload'
  end
end
