require File.expand_path('../test_helper', __dir__)

# Through the whole middleware stack: the flash that repeats rejected
# values must fit in Redmine's session cookie, or the response fails with
# CookieOverflow after the comment has already been saved.
class RedmineIssueForms::FlashCookieTest < Redmine::IntegrationTest
  include RedmineIssueForms::TestSetup
  Keys = RedmineIssueForms::Keys

  fixtures :projects, :users, :email_addresses, :user_preferences, :roles, :members, :member_roles,
           :issues, :issue_statuses, :trackers, :projects_trackers, :enabled_modules, :enumerations,
           :journals, :journal_details, :workflows

  def setup
    super
    enable_issue_forms
    User.find(2).update!(language: 'ru')
  end

  def teardown
    restore_settings
    super
  end

  test 'many long conflicting values still redirect with a warning' do
    rows = (0...20).map { |i| "| Позиция номер #{i} |  |" }.join("\n")
    table = 'Приёмка партии товара'
    column = 'Замечания и комментарии проверяющего'
    issue = form_issue("*#{table}*\n\n|_. Позиция |_. #{column} |\n#{rows}\n|\\2. Добавьте строки |\n")
    add_note(issue, (0...20).map { |i| "#{table} : #{column} : #{i} : чужое" }.join("\n"))

    log_user('jsmith', 'jsmith')
    # a big saved query in the session too, as after visiting the issue list
    get '/projects/ecookbook/issues', params: { set_filter: 1, f: ['subject'], op: { subject: '~' }, v: { subject: ['ж' * 200] } }
    values = (0...20).to_h { |i| [Keys.cell_id(table, column, i), 'ж' * 200] }
    values[Keys.new_cell_id(table, 'Позиция')] = 'Шайба'
    assert_difference 'Journal.count', 1 do
      post "/issues/#{issue.id}/form_values", params: { issue_form: { values: values } }
    end
    assert_response :redirect
    follow_redirect!
    assert_response :success
    assert_select '.flash.warning'
  end
end
