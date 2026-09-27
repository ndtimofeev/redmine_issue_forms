module RedmineIssueForms
  # Hooks the plugin into the one place every issue description is turned
  # into HTML: ApplicationHelper#textilizable. Core has no view hook that
  # could *replace* the description (view_issues_show_description_bottom
  # only appends below it), and doing it in the browser with JavaScript is
  # what failed in mobile Firefox for redmine-custom-decrement-field, so the
  # description is rendered server side, here.
  #
  # The override is deliberately narrow: it only acts on
  # textilizable(issue, :description, ...) for an issue that is a form (see
  # RedmineIssueForms.form_issue?) and passes every other call - journals,
  # wiki pages, previews, other issues - straight to core.
  #
  # :event_description is the same text under another name: Atom feeds
  # (common/feed.atom.builder) render events with it, and for an issue
  # acts_as_event maps it to the description.
  module ApplicationHelperPatch
    DESCRIPTION_ATTRIBUTES = %w[description event_description].freeze

    def textilizable(*args)
      issue = args[0]
      if issue.is_a?(Issue) && DESCRIPTION_ATTRIBUTES.include?(args[1].to_s) &&
         issue.description.present? && RedmineIssueForms.form_issue?(issue)
        # textilizable mutates its options (it deletes :only_path), so the
        # caller's hash is left alone.
        options = args.last.is_a?(Hash) ? args.last.dup : {}
        rendered = RedmineIssueForms::Renderer.new(self, issue).render do |text|
          # The one-argument form with :object renders +text+ exactly like
          # the description (same project, same attachments for inline
          # images). The :attribute is left out on purpose: it is only used
          # as part of the formatted-text cache key, and the rewritten text
          # differs on every render anyway because of the marker nonce.
          super(text, options.merge(object: issue))
        end
        return rendered if rendered
      end
      super
    end
  end
end
