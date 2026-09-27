require File.expand_path('../test_helper', __dir__)

class RedmineIssueForms::SettingsTest < Redmine::ControllerTest
  include RedmineIssueForms::TestSetup
  tests SettingsController

  fixtures :users, :trackers

  def setup
    enable_issue_forms
    @request.session[:user_id] = 1
  end

  def teardown
    restore_settings
  end

  test 'warns when the text formatting is not Textile' do
    get :plugin, params: { id: 'redmine_issue_forms' }
    assert_select '.flash.warning', 0

    Setting.text_formatting = 'common_mark'
    get :plugin, params: { id: 'redmine_issue_forms' }
    assert_select '.flash.warning', text: /common_mark/
  end
end
