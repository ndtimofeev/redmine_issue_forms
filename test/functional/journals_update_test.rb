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

  test 'a value of a table that stopped being a form reloads too' do
    @issue.update_columns(description: "*Items*\n\n|_. Item |_. Qty |\n|\\2. Add items |\n")
    journal = add_note(@issue, 'Items : Item : 0 : Bolt')
    @issue.init_journal(User.find(1))
    @issue.update!(description: "*Items*\n\n|_. Item |_. Qty |\n| Nut | 7 |\n")
    edit_note(journal, 'Items : Item : 0 : Nut')
    assert_includes response.body, 'window.location.reload()'
  end

  test 'an unrelated comment leaves the page alone' do
    edit_note(add_note(@issue, 'Looks good'), 'Looks good to me')
    assert_not_includes response.body, 'reload'
  end
end
