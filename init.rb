# Loaded by Redmine's PluginLoader inside a to_prepare block, i.e. on boot
# and again on every code reload in development - which is why the patch
# below is applied right here and not from another to_prepare block
# registered here: by the time init.rb runs, the first round of to_prepare
# callbacks has already fired, so such a block would miss the initial boot
# (the lesson learned in redmine_default_tab).

unless ApplicationHelper.include?(RedmineIssueForms::ApplicationHelperPatch)
  ApplicationHelper.prepend(RedmineIssueForms::ApplicationHelperPatch)
end
# Referenced so Zeitwerk loads it and its render_on/listener registers.
RedmineIssueForms::Hooks

Redmine::Plugin.register :redmine_issue_forms do
  name 'Issue Forms'
  author 'ndtimofeev'
  description 'Turns an issue description into a fill-in form: placeholders in lists and ' \
              'named tables are filled through ordinary issue comments ("Key : value").'
  version '0.1.0'
  url 'https://github.com/ndtimofeev/redmine_issue_forms'
  requires_redmine version_or_higher: '6.0.0'

  settings default: { 'tracker_ids' => [] }, partial: 'settings/redmine_issue_forms'

  # A project module is only listed in project settings when it declares at
  # least one permission. This one is public (granted to everyone, and not
  # shown in the roles/permissions matrix), so it adds no new permission to
  # manage: it just makes "is the module enabled" part of the usual
  # authorize check. Who may actually fill a form is decided by
  # add_issue_notes, see IssueFormValuesController#authorize_form.
  project_module RedmineIssueForms::PROJECT_MODULE do
    permission :fill_issue_forms, { issue_form_values: [:create] }, public: true
  end
end
