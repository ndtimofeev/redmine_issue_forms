require File.expand_path('../test_helper', __dir__)

# The form as drawn on the issue page, and read-only everywhere else.
class RedmineIssueForms::IssuesShowTest < Redmine::ControllerTest
  include RedmineIssueForms::TestSetup
  tests IssuesController
  Keys = RedmineIssueForms::Keys

  fixtures :projects, :users, :email_addresses, :user_preferences, :roles, :members, :member_roles,
           :issues, :issue_statuses, :trackers, :projects_trackers, :issue_categories,
           :enabled_modules, :enumerations, :journals, :journal_details, :workflows,
           :attachments, :custom_fields, :custom_values, :custom_fields_projects, :custom_fields_trackers,
           :versions, :watchers, :issue_relations, :time_entries

  TEMPLATE = <<~T.freeze
    h3. Acceptance

    * Passport
    ** Series: {}
    ** Number: {}
    * Bad: {} {}

    *T*

    |_. Item |_. Qty |
    | Bolt   |       |
    |\\2. Add rows below |
  T

  def setup
    enable_issue_forms
    @issue = form_issue(TEMPLATE)
  end

  def teardown
    restore_settings
  end

  test 'empty fields are inputs, filled ones are values with an edit link' do
    add_note(@issue, "Passport_Number : <script>alert(1)</script>\nT : Item : 1 : Nut")
    @request.session[:user_id] = 2
    get :show, params: { id: @issue.id }
    assert_response :success

    assert_select '#issue_description_wiki form.issue-form[action=?]', "/issues/#{@issue.id}/form_values" do
      assert_select 'h3', text: /Acceptance/
      assert_select "input.issue-form-input##{Keys.field_id('Passport_Series')}"
      assert_select "span.issue-form-value##{Keys.field_id('Passport_Number')}", text: '<script>alert(1)</script>'
      assert_select "a.issue-form-edit[href=?]", "/issues/#{@issue.id}?issue_form_edit=#{Keys.field_id('Passport_Number')}##{Keys.field_id('Passport_Number')}"
      # template row 0: Qty is an input; row 1 exists because of the comment
      assert_select "input##{Keys.cell_id('T', 'Qty', 0)}"
      assert_select "span.issue-form-value##{Keys.cell_id('T', 'Item', 1)}", text: 'Nut'
      assert_select "input##{Keys.cell_id('T', 'Qty', 1)}"
      # blank row under the tail
      assert_select "input##{Keys.new_cell_id('T', 'Item')}"
      assert_select 'button.issue-form-add-row'
      assert_select 'td[colspan="2"]', text: /Add rows below/
      assert_select 'input[name="issue_form[seen]"]'
    end
    assert_not_includes response.body, '<script>alert(1)</script>'
    assert_select '.issue-form-problems li', 1
  end

  test 'the form carries the CSRF token' do
    ActionController::Base.allow_forgery_protection = true
    @request.session[:user_id] = 2
    get :show, params: { id: @issue.id }
    assert_select '#issue_description_wiki form.issue-form input[name=authenticity_token]'
  ensure
    ActionController::Base.allow_forgery_protection = false
  end

  test 'edit mode draws the value in an input' do
    add_note(@issue, 'Passport_Series : 45 12')
    @request.session[:user_id] = 2
    get :show, params: { id: @issue.id, issue_form_edit: Keys.field_id('Passport_Series') }
    assert_select "input##{Keys.field_id('Passport_Series')}[value=?]", '45 12'
    assert_select 'input[name="issue_form[edited][]"][value=?]', Keys.field_id('Passport_Series')
    assert_select 'a.issue-form-cancel'
  end

  test 'read-only for people who cannot add notes' do
    Role.anonymous.remove_permission!(:add_issue_notes)
    add_note(@issue, 'Passport_Series : 4512')
    get :show, params: { id: @issue.id }
    assert_response :success
    assert_select '#issue_description_wiki form', 0
    assert_select '#issue_description_wiki input', 0
    assert_select '#issue_description_wiki .issue-form-edit', 0
    assert_select "span.issue-form-value##{Keys.field_id('Passport_Series')}", text: '4512'
    assert_select "span.issue-form-empty##{Keys.field_id('Passport_Number')}", text: '—'
    assert_select '.issue-form-problems', 0
  end

  test 'private notes do not fill the form' do
    add_note(@issue, 'Passport_Series : hidden', private_notes: true)
    @request.session[:user_id] = 2
    get :show, params: { id: @issue.id }
    assert_select "input##{Keys.field_id('Passport_Series')}"
  end

  test 'untouched when the issue is not a form' do
    Setting.plugin_redmine_issue_forms = { 'tracker_ids' => [] }
    @request.session[:user_id] = 2
    get :show, params: { id: @issue.id }
    assert_select '#issue_description_wiki form', 0
    assert_select '#issue_description_wiki li', text: /Series: \{\}/
  end

  test 'PDF export renders read-only' do
    add_note(@issue, 'Passport_Series : 4512')
    @request.session[:user_id] = 2
    get :show, params: { id: @issue.id, format: 'pdf' }
    assert_response :success
    assert_equal 'application/pdf', response.media_type
  end

  test 'e-mail notification shows values, no inputs' do
    add_note(@issue, 'Passport_Series : 4512')
    ActionMailer::Base.deliveries.clear
    with_settings notified_events: %w(issue_added) do
      Mailer.deliver_issue_add(@issue.reload)
    end
    mail = ActionMailer::Base.deliveries.last
    html = mail.html_part.body.to_s
    assert_includes html, '4512'
    assert_not_includes html, '<input'
    assert_not_includes html, 'ifm'
  end
end
