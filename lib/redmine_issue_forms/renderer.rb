require 'securerandom'

module RedmineIssueForms
  # Renders the description of a form issue.
  #
  # How it works:
  # 1. Every placeholder and every form table cell in the Textile *source*
  #    is replaced with a unique marker word ("ifm3fa91c07n12z"), extra
  #    rows written by comments and the blank "new row" are added to the
  #    tables as ordinary Textile rows made of markers.
  # 2. That text goes through Redmine's own textilizable, untouched - so
  #    headings, links, macros, attachments and escaping behave exactly as
  #    in any other description.
  # 3. Each marker in the resulting HTML is swapped, in one pass, for the
  #    HTML we built ourselves: a value, an input, a save button...
  #
  # Markers are lowercase letters and digits only, so Textile leaves them
  # alone (upper case could be turned into an <acronym>, "_" into
  # emphasis), and they carry a random per-render nonce, so text typed
  # into a description or a value can never be mistaken for one.
  #
  # Inputs are only drawn on the issue page itself (issues#show as HTML)
  # for people who may add notes. Everywhere else the same description is
  # rendered read-only - e-mail notifications, the PDF export, the
  # description column of issue lists - showing values where there are
  # some and a dash where there aren't.
  class Renderer
    include Redmine::I18n

    # +view+ is the view context textilizable was called on.
    def initialize(view, issue)
      @view = view
      @issue = issue
      @markers = []
      @nonce = SecureRandom.hex(4)
      @has_inputs = false
    end

    # Yields the rewritten Textile source to the block, which must render
    # it the way core would (see ApplicationHelperPatch). Returns nil when
    # the description isn't a form at all, so the caller falls back to
    # core rendering untouched.
    def render
      template = Template.parse(@issue.description)
      return nil if template.empty?

      @form = Form.new(template, Form.notes_for(@issue))
      html = yield(build_source).to_str
      html = html.gsub(/ifm#{@nonce}n(\d+)z/) { @markers[Regexp.last_match(1).to_i] }
      html = html.html_safe # rubocop:disable Rails/OutputSafety - every inserted piece is built with escaping helpers below

      html = wrap_in_form(html) if interactive? && @has_inputs
      html + notes_block
    end

    private

    attr_reader :view, :form

    def template
      form.template
    end

    # --- where inputs are allowed -----------------------------------------

    def interactive?
      return @interactive if defined?(@interactive)

      @interactive = issue_page? && RedmineIssueForms.fillable?(@issue)
    end

    # Only the HTML issue page. Checked on the controller object rather
    # than with the controller_name helper because textilizable is also
    # called from mailer views, where there is no such helper.
    def issue_page?
      controller = view.respond_to?(:controller) ? view.controller : nil
      return false unless controller.is_a?(ActionController::Base)
      return false unless controller.controller_name == 'issues' && controller.action_name == 'show'

      controller.request.format.html?
    end

    def editing_id
      interactive? ? view.params[:issue_form_edit].to_s.presence : nil
    end

    # --- source rewriting --------------------------------------------------

    def marker(html)
      @markers << html
      "ifm#{@nonce}n#{@markers.size - 1}z"
    end

    def build_source
      lines = template.lines.dup

      template.fields.group_by(&:line_index).each do |line_index, fields|
        line = lines[line_index].dup
        # Right to left, so earlier offsets stay valid.
        fields.sort_by(&:start).reverse_each do |field|
          line[field.start, field.length] = marker(field_html(field))
        end
        lines[line_index] = line
      end

      template.form_tables.each do |table|
        lines[table.first_line_index] = table_source(table)
        ((table.first_line_index + 1)..table.last_line_index).each { |index| lines[index] = nil }
      end

      lines.compact.join("\n")
    end

    def table_source(table)
      rows = [template.lines[table.header.line_index]]

      form.row_count(table).times do |row|
        rows <<
          if row < table.template_row_count
            template_row_source(table, table.rows[row], row)
          else
            extra_row_source(table, row)
          end
      end

      rows << template.lines[table.tail.line_index] if table.tail
      rows << new_row_source(table) if interactive? && form.can_add_row?(table)
      rows.join("\n")
    end

    # A row of the template: static cells keep their text, empty ones get
    # a marker. A row without any empty cell is kept byte for byte.
    def template_row_source(table, row, row_index)
      return template.lines[row.line_index] if row.cells.none?(&:input?)

      contents = row.cells.map do |cell|
        next cell.content unless cell.input?

        marker(cell_html(form.cell_target(table, cell.column, row_index)))
      end
      row_line(row.cells.map(&:prefix), contents)
    end

    # A row that exists only because comments wrote to it.
    def extra_row_source(table, row_index)
      contents = table.columns.each_index.map do |column|
        marker(cell_html(form.cell_target(table, column, row_index)))
      end
      row_line([''] * contents.size, contents)
    end

    # The blank row under the tail; saving it creates the next row. Its
    # check marks are titled "Add row" rather than "Save".
    def new_row_source(table)
      contents = table.columns.map do |column_name|
        id = Keys.new_cell_id(table.name, column_name)
        marker(input_tag(id, nil, label: "#{table.name} : #{column_name}", placeholder: column_name,
                                  button: add_row_button))
      end
      row_line([''] * contents.size, contents)
    end

    def row_line(prefixes, contents)
      cells = prefixes.zip(contents).map { |prefix, content| prefix.empty? ? " #{content} " : "#{prefix} #{content} " }
      "|#{cells.join('|')}|"
    end

    # --- HTML pieces -------------------------------------------------------

    def field_html(field)
      unless field.valid?
        return ERB::Util.h(field.source) unless interactive?

        return view.content_tag(:span, field.source, class: 'issue-form-problem', title: problem_text(field.problem))
      end

      target = form.targets[field.id]
      entry = form.value_for(target)
      if interactive? && (entry.nil? || editing_id == field.id)
        input_tag(field.id, entry&.value, label: field.key, edited: entry.present?) + cancel_link(field.id, entry)
      elsif entry
        value_html(field.id, entry.value)
      else
        view.content_tag(:span, '—', class: 'issue-form-empty', id: field.id)
      end
    end

    def cell_html(target)
      entry = form.value_for(target)
      label = form.target_label(target)
      if interactive? && (entry.nil? || editing_id == target.id)
        input_tag(target.id, entry&.value, label: label, edited: entry.present?) + cancel_link(target.id, entry)
      elsif entry
        value_html(target.id, entry.value)
      else
        ''
      end
    end

    def value_html(id, value)
      html = view.content_tag(:span, value, class: 'issue-form-value', id: id)
      html += ' '.html_safe + edit_link(id) if interactive?
      html
    end

    # An input with its check mark button drawn inside it, at the right
    # end (see .issue-form-field in the stylesheet): a wrapper span is the
    # positioning box, the input leaves room on its right for the button.
    # Every input gets its own check mark, in tables too, so the button is
    # always right where the person was typing.
    def input_tag(id, value, label:, edited: false, placeholder: nil, button: save_button)
      @has_inputs = true
      html = view.text_field_tag(
        "issue_form[values][#{id}]", value,
        id: id, class: 'issue-form-input', placeholder: placeholder, 'aria-label': label,
        # The pencil link lands on this input: put the cursor in it.
        autofocus: edited && editing_id == id
      )
      html += button
      # Marks the input as opened with the pencil: only such inputs may
      # overwrite or clear an existing value (see Submission).
      html += view.hidden_field_tag('issue_form[edited][]', id, id: nil) if edited
      view.content_tag(:span, html, class: 'issue-form-field')
    end

    def save_button
      ok_button(l(:button_save), 'issue-form-save')
    end

    def add_row_button
      ok_button(l(:button_issue_forms_add_row), 'issue-form-add-row')
    end

    # A small button showing just a green check mark instead of a text
    # label; the words stay available as a tooltip and to screen readers.
    #
    # The mark is the text character U+2714 followed by U+FE0E (variation
    # selector "text presentation", so phones don't swap it for a colour
    # emoji), coloured with CSS. Core's SVG "checked" sprite was tried
    # first, but inside a button it rendered clipped and blurry in
    # Chromium; a glyph needs no sprite and scales with the font.
    def ok_button(title, css_class)
      view.button_tag(
        view.content_tag(:span, "\u2714\uFE0E", class: 'issue-form-ok-mark', 'aria-hidden': true),
        type: 'submit', name: nil, class: "issue-form-ok #{css_class}", title: title, 'aria-label': title
      )
    end

    def edit_link(id)
      view.link_to(
        view.sprite_icon('edit', l(:button_edit), icon_only: true),
        view.issue_path(@issue, issue_form_edit: id, anchor: id),
        class: 'icon-only icon-edit issue-form-edit', title: l(:button_edit)
      )
    end

    def cancel_link(id, entry)
      return ''.html_safe unless entry && editing_id == id

      ' '.html_safe + view.link_to(l(:button_cancel), view.issue_path(@issue, anchor: id), class: 'issue-form-cancel')
    end

    # One form around the whole description: every check mark button
    # submits everything that was typed (see Submission). Wrapping the
    # description instead of using per-row <form> elements keeps the markup
    # valid - a <form> can't sit inside a <tr> - and needs no JavaScript at
    # all. There is no separate "save all" button at the bottom: every
    # input has its own check mark, and any of them, or Enter, saves
    # everything.
    def wrap_in_form(html)
      footer = view.hidden_field_tag('issue_form[seen]', form.last_journal_id, id: nil)
      # form_tag without a block returns just the opening tag (with the
      # CSRF token), which avoids depending on the view's output buffer.
      view.form_tag(view.issue_form_values_path(@issue), method: :post, class: 'issue-form', id: 'issue-form') +
        html + footer + '</form>'.html_safe
    end

    # Template problems and orphaned table values, shown only to people
    # who can fill the form - they are the ones who can fix it.
    def notes_block
      return ''.html_safe unless interactive?

      html = ''.html_safe
      problems = (template.fields + template.tables).filter_map(&:problem).uniq
      if problems.any?
        html += view.content_tag(:div, class: 'issue-form-problems') do
          view.content_tag(:p, l(:label_issue_forms_problems), class: 'issue-form-notes-title') +
            view.content_tag(:ul, view.safe_join(problems.map { |problem| view.content_tag(:li, problem_text(problem)) }))
        end
      end

      if form.orphans.any?
        html += view.content_tag(:div, class: 'issue-form-orphans') do
          items = form.orphans.map do |orphan|
            view.content_tag(:li) do
              view.link_to(orphan.line, view.issue_path(@issue, anchor: "change-#{orphan.journal_id}")) +
                " (#{l(:"text_issue_forms_orphan_#{orphan.reason}")})"
            end
          end
          view.content_tag(:p, l(:label_issue_forms_orphans), class: 'issue-form-notes-title') +
            view.content_tag(:ul, view.safe_join(items))
        end
      end
      html
    end

    def problem_text(problem)
      l(:"text_issue_forms_problem_#{problem.code}", **problem.args)
    end
  end
end
