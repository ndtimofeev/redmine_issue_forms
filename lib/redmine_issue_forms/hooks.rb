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
    # comment's own HTML (journals/update.js.erb), but the form in the
    # description is derived from the comments. When the comment had or
    # has form values, the page is reloaded so the form shows what is now
    # true - unless something is typed on the page (form fields, a note, a
    # comment being edited), which a reload would throw away: then a note
    # above the description asks to reload instead.
    def view_journals_update_js_bottom(context = {})
      journal = context[:journal]
      issue = journal&.journalized
      return '' unless issue.is_a?(Issue) && RedmineIssueForms.form_issue?(issue)
      return '' unless self.class.form_comment?(issue, journal)

      message = escape_javascript(l(:text_issue_forms_comments_changed))
      <<~JS
        (function() {
          var changed = function() { return String(this.value).trim() !== String(this.defaultValue).trim(); };
          if ($('.issue-form-input, textarea').filter(changed).length === 0) {
            window.location.reload();
          } else if ($('#issue-form-comments-changed').length === 0) {
            $('<div class="flash warning" id="issue-form-comments-changed"></div>')
              .text('#{message}').insertBefore('#issue_description_wiki');
          }
        })();
      JS
    end

    # Whether +journal+'s notes, before or after the edit that just
    # happened, hold anything the form reads. The text before the edit is
    # notes_before_last_save after a normal edit, but notes_in_database
    # when the comment was emptied: Journal#save then refuses to save and
    # the controller destroys the journal instead. Private notes are not
    # told apart - making a comment private or public changes the form
    # too, and a needless reload for a private one is harmless.
    def self.form_comment?(issue, journal)
      template = Template.parse(issue.description)
      return false if template.empty?

      texts = [journal.notes_before_last_save, journal.notes_in_database, journal.notes].compact.uniq
      texts.any? { |text| Form.new(template, [[journal.id.to_i, text.to_s]]).reads_any? }
    end
  end
end
