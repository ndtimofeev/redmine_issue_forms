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

  test 'conflict warning is escaped and repeats what was typed' do
    @issue.update_columns(description: "* Date: {<b>Date</b>}\n")
    add_note(@issue, '<b>Date</b> : theirs')
    assert_no_difference 'Journal.count' do
      post_values(Keys.field_id('<b>Date</b>') => '<i>mine</i>')
    end
    assert_includes flash[:warning], '&lt;b&gt;Date&lt;/b&gt;'
    assert_includes flash[:warning], '&lt;i&gt;mine&lt;/i&gt;'
    assert_nil flash[:notice] # no "nothing to save" next to the warning
  end

  test 'rejected values are repeated back within a small number of bytes' do
    User.find(2).update!(language: 'ru')
    rows = (0...12).map { |i| "| Позиция номер #{i} |  |" }.join("\n")
    @issue.update_columns(description: "*Приёмка партии*\n\n|_. Позиция |_. Замечания и комментарии проверяющего |\n#{rows}\n")
    add_note(@issue, (0...12).map { |i| "Приёмка партии : Замечания и комментарии проверяющего : #{i} : чужое" }.join("\n"))
    values = (0...12).to_h { |i| [Keys.cell_id('Приёмка партии', 'Замечания и комментарии проверяющего', i), 'ж' * 80] }
    values.merge!((1..12).to_h { |i| ["ifv-#{format('%016x', i)}", '<ё>' * 40] })
    post_values(values)
    warning = flash[:warning]
    assert_operator warning.bytesize, :<=, IssueFormValuesController::FLASH_BYTES
    assert_includes warning, '...'
    assert_includes warning, '&lt;ё&gt;'
    assert_no_match(/&(?![a-z]+;|#\d+;)/, warning) # never an entity cut in half
  end

  test 'long table and column names are shortened without losing the row number' do
    User.find(2).update!(language: 'ru')
    table = 'Приёмка партии товара'
    column = 'Замечания и комментарии проверяющего'
    rows = (0...5).map { |i| "| #{i} |  |" }.join("\n")
    @issue.update_columns(description: "*#{table}*\n\n|_. Позиция |_. #{column} |\n#{rows}\n")
    add_note(@issue, "#{table} : #{column} : 1 : чужое\n#{table} : #{column} : 3 : чужое")
    post_values(Keys.cell_id(table, column, 1) => 'трещина', Keys.cell_id(table, column, 3) => 'скол',
                Keys.cell_id(table, column, 4) => 'ок')
    assert_equal "#{table} : #{column} : 4 : ок", Journal.order(:id).last.notes
    assert_includes flash[:warning], ' : 1 (вы ввели «трещина»)'
    assert_includes flash[:warning], ' : 3 (вы ввели «скол»)'
  end

  test 'a short warning leaves the room it does not need to the others' do
    add_note(@issue, 'Date : theirs')
    stale = (1..8).to_h { |i| ["ifv-#{format('%016x', i)}", "value number #{i} #{'x' * 40}"] }
    post_values(stale.merge(Keys.field_id('Date') => 'mine'))
    warning = flash[:warning]
    assert_includes warning, 'Date (you typed'
    (1..8).each { |i| assert_includes warning, "value number #{i} " }
    assert_operator warning.bytesize, :<=, IssueFormValuesController::FLASH_BYTES
  end

  test 'a cleared value that could not be saved is reported as a clear' do
    add_note(@issue, 'Date : old')
    add_note(@issue, 'Date : theirs')
    date = Keys.field_id('Date')
    post :create, params: { id: @issue.id, issue_form: { values: { date => '' }, original: { date => 'old' } } }
    assert_match(/Date \(you cleared it\)/, flash[:warning])
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

  test 'the pencil saves what was typed and opens the value for editing' do
    add_note(@issue, 'T : B : 0 : old')
    cell = Keys.cell_id('T', 'B', 0)
    assert_difference 'Journal.count', 1 do
      post :create, params: { id: @issue.id, issue_form: { values: { Keys.field_id('Date') => 'today' }, open: cell } }
    end
    assert_equal 'Date : today', Journal.order(:id).last.notes
    assert_redirected_to "/issues/#{@issue.id}?issue_form_edit=#{cell}##{cell}"
  end

  test 'the pencil with nothing typed just opens the value' do
    cell = Keys.cell_id('T', 'B', 0)
    assert_no_difference 'Journal.count' do
      post :create, params: { id: @issue.id, issue_form: { values: {}, open: cell } }
    end
    assert_redirected_to "/issues/#{@issue.id}?issue_form_edit=#{cell}##{cell}"
    assert_nil flash[:notice]
  end

  test 'Cancel leaves the opened value alone and saves the rest' do
    add_note(@issue, 'Date : old')
    date = Keys.field_id('Date')
    post :create, params: { id: @issue.id, issue_form: {
      values: { date => 'changed', Keys.cell_id('T', 'B', 0) => 'b0' }, original: { date => 'old' }, cancel: date
    } }
    assert_equal 'T : B : 0 : b0', Journal.order(:id).last.notes
    assert_nil flash[:warning]
    assert_redirected_to "/issues/#{@issue.id}##{Keys.cell_id('T', 'B', 0)}"
  end

  test 'open and cancel must be field ids' do
    post :create, params: { id: @issue.id, issue_form: { values: {}, open: 'x" onclick="alert(1)' } }
    assert_redirected_to "/issues/#{@issue.id}#issue_description_wiki"
  end

  test 'malformed params are ignored' do
    assert_no_difference 'Journal.count' do
      post :create, params: { id: @issue.id, issue_form: { values: { Keys.field_id('Date') => { 'a' => 'b' } } } }
    end
    assert_response :redirect
  end
end
