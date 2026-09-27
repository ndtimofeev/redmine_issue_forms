require File.expand_path('../test_helper', __dir__)

class IssueFormValuesControllerTest < Redmine::ControllerTest
  include RedmineIssueForms::TestSetup
  Keys = RedmineIssueForms::Keys

  fixtures :projects, :users, :email_addresses, :user_preferences, :roles, :members, :member_roles,
           :issues, :issue_statuses, :trackers, :projects_trackers, :issue_categories,
           :enabled_modules, :enumerations, :journals, :journal_details, :workflows

  TEMPLATE = <<~T.freeze
    * Date: {}

    *T*

    |_. A |_. B |
    | x   |     |
    |\\2. |
  T

  def setup
    enable_issue_forms
    @issue = form_issue(TEMPLATE)
    @request.session[:user_id] = 2
  end

  def teardown
    restore_settings
  end

  def post_values(values)
    post :create, params: { id: @issue.id, issue_form: { values: values } }
  end

  test 'saves typed values as one comment by the current user' do
    assert_difference 'Journal.count', 1 do
      post_values(Keys.field_id('Date') => '2026-09-27', Keys.cell_id('T', 'B', 0) => 'b0')
    end
    journal = Journal.order(:id).last
    assert_equal "Date : 2026-09-27\nT : B : 0 : b0", journal.notes
    assert_equal 2, journal.user_id
    assert_not journal.private_notes?
    assert_redirected_to "/issues/#{@issue.id}##{Keys.field_id('Date')}"
    assert_equal 'Saved', flash[:notice]
  end

  test 'new row gets the next index' do
    add_note(@issue, 'T : A : 1 : first')
    post_values(Keys.new_cell_id('T', 'A') => 'second')
    assert_equal 'T : A : 2 : second', Journal.order(:id).last.notes
  end

  test 'nothing typed adds no comment' do
    assert_no_difference 'Journal.count' do
      post_values(Keys.field_id('Date') => '')
    end
    assert_redirected_to "/issues/#{@issue.id}#issue_description_wiki"
  end

  test 'conflict warning is escaped' do
    @issue.update_columns(description: "* <b>Date</b>: {}\n")
    add_note(@issue, '<b>Date</b> : theirs')
    assert_no_difference 'Journal.count' do
      post_values(Keys.field_id('<b>Date</b>') => 'mine')
    end
    assert_includes flash[:warning], '&lt;b&gt;Date&lt;/b&gt;'
  end

  test 'requires add_issue_notes' do
    Role.find(1).remove_permission!(:add_issue_notes)
    assert_no_difference 'Journal.count' do
      post_values(Keys.field_id('Date') => 'x')
    end
    assert_response :forbidden
  end

  test 'anonymous is sent to log in' do
    Role.anonymous.remove_permission!(:add_issue_notes)
    @request.session[:user_id] = nil
    post_values(Keys.field_id('Date') => 'x')
    assert_response :redirect
    assert_match %r{/login}, response.location
  end

  test '404 when the issue is not a form' do
    Setting.plugin_redmine_issue_forms = { 'tracker_ids' => ['2'] }
    post_values(Keys.field_id('Date') => 'x')
    assert_response :not_found
  end

  test '404 when the module is disabled' do
    Project.find(1).disable_module!(RedmineIssueForms::PROJECT_MODULE)
    post_values(Keys.field_id('Date') => 'x')
    assert_response :not_found
  end

  test '404 with another text formatting' do
    Setting.text_formatting = 'common_mark'
    post_values(Keys.field_id('Date') => 'x')
    assert_response :not_found
  end

  test 'malformed params are ignored' do
    assert_no_difference 'Journal.count' do
      post :create, params: { id: @issue.id, issue_form: { values: { Keys.field_id('Date') => { 'a' => 'b' } } } }
    end
    assert_response :redirect
  end
end
