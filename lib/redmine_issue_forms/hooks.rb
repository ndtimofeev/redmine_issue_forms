module RedmineIssueForms
  # Inline <style> in <head> on every page, rather than a
  # stylesheet_link_tag: Redmine 6 serves plugin assets through Propshaft,
  # and on a real deployment of redmine-custom-decrement-field a <link> to
  # a plugin asset 404ed silently whenever `assets:precompile` hadn't been
  # run. The CSS stays a normal file in assets/stylesheets for editing;
  # only the way it reaches the browser differs. Same approach as that
  # plugin, for the same reason.
  class Hooks < Redmine::Hook::ViewListener
    render_on :view_layouts_base_html_head, partial: 'redmine_issue_forms/stylesheet'

    def self.inline_stylesheet
      @inline_stylesheet ||= File.read(
        File.join(Redmine::Plugin.find(PLUGIN_ID).directory, 'assets', 'stylesheets', 'redmine_issue_forms.css')
      )
    end

    # Editing or deleting a comment on the issue page swaps only that
    # comment's own HTML (journals/update.js.erb). The form in the
    # description is derived from the comments, so it would keep showing
    # the old values until the next reload - reload right away instead.
    def view_journals_update_js_bottom(context = {})
      issue = context[:journal]&.journalized
      return '' unless issue.is_a?(Issue) && RedmineIssueForms.form_issue?(issue)

      'window.location.reload();'
    end
  end
end
