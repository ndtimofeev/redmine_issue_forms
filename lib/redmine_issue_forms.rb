# Top-level namespace of the plugin, plus the handful of plugin-wide
# questions every other part asks: "is this issue a form at all?" and
# "which trackers are configured as forms?".
#
# This file and everything under lib/redmine_issue_forms/ is loaded by
# Zeitwerk (Redmine 6 pushes every plugin's lib/ onto the main
# autoloader, see lib/redmine/plugin_loader.rb in core), so there are no
# require/require_relative calls anywhere in the plugin: referencing
# RedmineIssueForms::Template is enough to load
# lib/redmine_issue_forms/template.rb.
module RedmineIssueForms
  PLUGIN_ID = :redmine_issue_forms

  # Name of the project module that switches forms on for a project
  # (Project settings -> Modules). See init.rb for why the module carries
  # a public permission.
  PROJECT_MODULE = :issue_forms

  # Only Textile is supported for now: the template syntax (lists written
  # with "*"/"#", tables with "|_." headers and "|\3." colspan tails) is
  # Textile's. With any other text formatting the plugin stays completely
  # inert - descriptions render exactly as core renders them and the save
  # endpoint answers 404.
  SUPPORTED_TEXT_FORMATTING = 'textile'.freeze

  # Upper bound on how many data rows a single table can grow to through
  # comments. Without it, one hand-written comment such as
  # "Table : Column : 999999 : x" would make every page view render a
  # million rows. Values that point past this limit are reported as
  # orphaned (see Form#orphans) instead of being silently dropped.
  MAX_TABLE_ROWS = 200

  # ...and on how many cells, so that a very wide table can't multiply
  # that bound: a table's row limit is the smaller of MAX_TABLE_ROWS and
  # MAX_TABLE_CELLS / its number of columns (see Form#row_limit).
  MAX_TABLE_CELLS = 2000

  class << self
    def settings
      Setting.plugin_redmine_issue_forms || {}
    end

    # Tracker ids (as strings, the way Setting stores them) whose issues
    # are forms. The settings page always posts an extra blank entry so
    # that unchecking every tracker still saves an (empty) list - it is
    # filtered out here.
    def tracker_ids
      Array(settings['tracker_ids']).map(&:to_s).reject(&:blank?)
    end

    def textile?
      Setting.text_formatting.to_s == SUPPORTED_TEXT_FORMATTING
    end

    # The single "is this issue a form?" check used by the renderer and
    # the controller alike: the formatting is Textile, the issue's tracker
    # is listed in the plugin settings and the issue's project has the
    # module enabled. Deliberately says nothing about the current user -
    # whether someone may *fill* the form is a separate question (see
    # .fillable?).
    def form_issue?(issue)
      return false unless issue.is_a?(Issue) && issue.project && issue.tracker_id
      return false unless textile?
      return false unless tracker_ids.include?(issue.tracker_id.to_s)

      issue.project.module_enabled?(PROJECT_MODULE).present?
    end

    # Filling a field is literally adding a comment, so the right to fill
    # a form is exactly the right to add notes to that issue (which
    # already takes per-tracker role permissions and closed/archived
    # projects into account, see Issue#notes_addable?). No dedicated
    # permission is introduced.
    def fillable?(issue, user = User.current)
      form_issue?(issue) && issue.visible?(user) && issue.notes_addable?(user)
    end
  end
end
