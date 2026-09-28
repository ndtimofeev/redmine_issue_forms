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

    # Saving the form leaves the page, and core's warning about unsaved
    # text (warnLeavingUnsaved in application.js) is switched off by any
    # form submit - so a note half typed in the issue's Edit panel would be
    # lost without a word when someone presses a check mark. This asks
    # first, with core's own message and only when core would have warned
    # (the message global exists only if the user's preference is on).
    # stopImmediatePropagation keeps a cancelled submit from reaching the
    # other submit handlers: rails-ujs' (on document), which would disable
    # every button, and core's double-submit guard
    # (addFormObserversForDoubleSubmit, bound to this same form), which
    # would take the cancelled submit for a first one and block every
    # later one. The inline handler runs before both, and stops them only
    # when the person chooses to stay. Without JavaScript the attribute
    # does nothing.
    UNSAVED_TEXT_GUARD =
      "if (window.warnLeavingUnsavedMessage && window.jQuery && " \
      "$('textarea').filter(function() { return $(this).data('changed'); }).length > 0 && " \
      "!confirm(window.warnLeavingUnsavedMessage)) { event.stopImmediatePropagation(); return false; }".freeze

    # +view+ is the view context textilizable was called on.
    def initialize(view, issue)
      @view = view
      @issue = issue
      @markers = []
      @nonce = SecureRandom.hex(4)
      @has_controls = false
    end

    # Yields the rewritten Textile source to the block, which must render
    # it the way core would (see ApplicationHelperPatch). Returns nil when
    # the description isn't a form at all, so the caller falls back to
    # core rendering untouched.
    def render
      template = Template.parse(@issue.description)
      # A description whose only table stopped being a form (see
      # Template#plain_table?) is still rendered here for people who can
      # fill it, so the values its comments gave that table are listed.
      return nil if template.empty? && !(template.plain_tables? && interactive?)

      # The history is only searched if the orphans are shown (see
      # #notes_block), so a read-only rendering never pays for it.
      @form = Form.new(template, Form.notes_for(@issue), former_names: ->(names) { Form.former_names_for(@issue, names) })
      html = substitute_markers(yield(build_source).to_str)
      html = html.html_safe # rubocop:disable Rails/OutputSafety - every inserted piece is built with escaping helpers below

      html = wrap_in_form(html) if interactive? && @has_controls
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

    # +plain+ is the text that stands for the marker where HTML can't go
    # (see #substitute_markers): the value, or the placeholder as written.
    def marker(html, plain = '', label: nil)
      @markers << [html, plain.to_s, label]
      "ifm#{@nonce}n#{@markers.size - 1}z"
    end

    # Put at the start of every header cell of a form table, to make its
    # column unsortable (see #unsortable_headers). Core makes every wiki
    # table with a header row sortable by clicking a column header
    # (setupWikiTableSortableHeader in application.js, using Tablesort),
    # but a form table's cells are addressed by row number: sorted, its
    # rows would no longer be where their comments say, and the blank new
    # row would end up somewhere in the middle.
    def header_pin
      "ifm#{@nonce}hz"
    end

    # Swaps markers for our HTML, in one pass per step so nothing inserted
    # is ever scanned again.
    #
    # Textile and Redmine can put a marker where HTML can't go: into a
    # tag - "{}@corp.ru" is auto-linked as an e-mail, "https://crm/{}" as a
    # URL, often in both the href and the link text - or into the text of
    # a link ("\"{}\":https://crm/"), where clicking the input would follow
    # the link. There only the plain text may go (the value, or "{}"); a
    # field caught this way gets no input anywhere, and people who can
    # fill the form are told why (#notes_block). A marker that appears
    # twice in text gets its HTML once and the plain text after that, so
    # no id is ever duplicated.
    #
    # Two passes over the same tokens (tags and markers): the first finds
    # the caught markers, wherever their other copies are; the second
    # swaps every marker.
    def substitute_markers(html)
      html = unsortable_headers(html)
      marker = /ifm#{@nonce}n(\d+)z/
      token = /<[^>]*>|#{marker}/

      @caught_in_tags = Set.new
      link_depth = 0
      html.scan(token) do
        piece = Regexp.last_match(0)
        index = Regexp.last_match(1)
        if piece.start_with?('<')
          piece.scan(marker) { @caught_in_tags << Regexp.last_match(1).to_i }
          if piece.match?(/\A<a[\s>]/i)
            link_depth += 1
          elsif piece.match?(%r{\A</a\s*>}i) && link_depth.positive?
            link_depth -= 1
          end
        elsif link_depth.positive?
          @caught_in_tags << index.to_i
        end
      end

      used = Set.new
      html.gsub(token) do
        piece = Regexp.last_match(0)
        index = Regexp.last_match(1)
        if piece.start_with?('<')
          piece.gsub(marker) { ERB::Util.h(@markers[Regexp.last_match(1).to_i][1]) }
        else
          html_piece, plain, = @markers[index.to_i]
          @caught_in_tags.include?(index.to_i) || !used.add?(index.to_i) ? ERB::Util.h(plain) : html_piece
        end
      end
    end

    # Every <th> that starts with a #header_pin gets what Tablesort and
    # core's stylesheet need to leave its column alone:
    # data-sort-method="none" (no click handler) and the class "no-sort"
    # (no pointer cursor, no sort arrow). The pins themselves are dropped,
    # wherever they ended up.
    def unsortable_headers(html)
      pin = header_pin
      html = html.gsub(/<th([^>]*)>[[:blank:]]*#{pin}[[:blank:]]*/) do
        attributes = Regexp.last_match(1)
        attributes =
          if attributes.match?(/\bclass="/)
            attributes.sub(/\bclass="/, 'class="no-sort ')
          else
            "#{attributes} class=\"no-sort\""
          end
        "<th#{attributes} data-sort-method=\"none\">"
      end
      html.gsub(/[[:blank:]]*#{pin}[[:blank:]]*/, '')
    end

    def build_source
      lines = template.lines.dup

      template.fields.group_by(&:line_index).each do |line_index, fields|
        line = lines[line_index].dup
        # Right to left, so earlier offsets stay valid.
        fields.sort_by(&:start).reverse_each do |field|
          line[field.start, field.length] = marker(field_html(field), plain_for_field(field), label: field.key)
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
      header = table.header.cells
      rows = [row_line(header.map(&:prefix), header.map { |cell| "#{header_pin} #{cell.content}" })]

      form.row_count(table).times do |row|
        rows <<
          if row < table.template_row_count
            template_row_source(table, table.rows[row], row)
          else
            extra_row_source(table, row)
          end
      end

      # An empty tail would be an empty row right above the new row.
      rows << template.lines[table.tail.line_index] if table.tail? && !table.tail.cells.first.content.empty?
      if interactive? && table.tail?
        rows << (form.can_add_row?(table) ? new_row_source(table) : full_row_source(table))
      end
      rows.join("\n")
    end

    # A row of the template: static cells keep their text, empty ones get
    # a marker. A row without any empty cell is kept byte for byte.
    def template_row_source(table, row, row_index)
      return template.lines[row.line_index] if row.cells.none?(&:input?)

      targets = row.cells.map { |cell| form.cell_target(table, cell.column, row_index) if cell.input? }
      buttons = row_buttons(targets)
      contents = row.cells.each_with_index.map do |cell, index|
        next cell.content unless cell.input?

        cell_marker(targets[index], button: buttons[index])
      end
      row_line(row.cells.map(&:prefix), contents)
    end

    # A row that exists only because comments wrote to it.
    def extra_row_source(table, row_index)
      targets = table.columns.each_index.map { |column| form.cell_target(table, column, row_index) }
      buttons = row_buttons(targets)
      contents = targets.each_with_index.map { |target, index| cell_marker(target, button: buttons[index]) }
      row_line([''] * contents.size, contents)
    end

    # One check mark per table row, in the last input of the row: several
    # in a row read as if each saved only its own cell, while every one of
    # them saves the whole form anyway (as does Enter in any input).
    # Returns the button for each of +targets+ (nil for a static cell, or
    # an input without the check mark).
    def row_buttons(targets)
      last = targets.rindex { |target| target && shows_input?(target) }
      targets.each_index.map { |index| index == last ? save_button : nil }
    end

    # The blank row under the tail; saving it creates the next row. Its
    # check mark is titled "Add row" rather than "Save".
    def new_row_source(table)
      contents = table.columns.each_with_index.map do |column_name, column|
        id = Keys.new_cell_id(table.name, column_name)
        button = column == table.columns.size - 1 ? add_row_button : nil
        marker(input_tag(id, nil, label: "#{table.name} : #{column_name}", placeholder: column_name, button: button))
      end
      row_line([''] * contents.size, contents)
    end

    # In place of the new row once a table has as many rows as it may
    # have, so the tail's invitation to add rows isn't left unexplained.
    def full_row_source(table)
      note = view.content_tag(:em, l(:text_issue_forms_table_full, count: form.row_limit(table)))
      "|\\#{table.columns.size}. #{marker(note)} |"
    end

    def cell_marker(target, button:)
      marker(cell_html(target, button: button), form.value_for(target)&.value, label: form.target_label(target))
    end

    def plain_for_field(field)
      (field.valid? && form.value_for(form.targets[field.id])&.value) || field.source
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
        input_tag(field.id, entry&.value, label: field.key, edited: entry.present?) + cancel_button(field.id, entry)
      elsif entry
        value_html(field.id, entry.value)
      else
        view.content_tag(:span, '—', class: 'issue-form-empty', id: field.id)
      end
    end

    # Whether +target+ is shown as an input: empty, or opened with the
    # pencil, to someone who can fill the form.
    def shows_input?(target)
      interactive? && (form.value_for(target).nil? || editing_id == target.id)
    end

    def cell_html(target, button:)
      entry = form.value_for(target)
      label = form.target_label(target)
      if shows_input?(target)
        input_tag(target.id, entry&.value, label: label, edited: entry.present?, button: button) +
          cancel_button(target.id, entry)
      elsif entry
        value_html(target.id, entry.value)
      else
        ''
      end
    end

    def value_html(id, value)
      html = view.content_tag(:span, value, class: 'issue-form-value', id: id)
      html += ' '.html_safe + edit_button(id) if interactive?
      html
    end

    # An input with its check mark button drawn inside it, at the right
    # end (see .issue-form-field in the stylesheet): a wrapper span is the
    # positioning box, the input leaves room on its right for the button.
    # Every list field gets its own check mark; a table row gets one, in
    # its last input (see #row_buttons), and the other inputs of the row
    # get +button+ nil.
    def input_tag(id, value, label:, edited: false, placeholder: nil, button: save_button)
      @has_controls = true
      # No type attribute - still a text input, but not one core's
      # defaultFocus() (application.js) picks up: it focuses the first
      # '#content input[type=text]' on every issue page opened without an
      # anchor, which would scroll the page down to the first empty field.
      html = view.tag.input(
        name: "issue_form[values][#{id}]", value: value,
        id: id, class: 'issue-form-input', placeholder: placeholder, 'aria-label': label,
        # The pencil lands on this input: put the cursor in it.
        autofocus: edited && editing_id == id
      )
      html += button if button
      # Marks the input as opened with the pencil, and remembers what it
      # showed: only such inputs may overwrite or clear an existing value,
      # and only if nobody changed it meanwhile (see Submission).
      html += view.hidden_field_tag("issue_form[original][#{id}]", value, id: nil) if edited
      view.content_tag(:span, html, class: button ? 'issue-form-field issue-form-with-ok' : 'issue-form-field')
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
      form_button(
        view.content_tag(:span, "\u2714\uFE0E", class: 'issue-form-ok-mark', 'aria-hidden': true),
        class: "issue-form-ok #{css_class}", title: title, 'aria-label': title
      )
    end

    # The pencil next to a value. A submit button of the form rather than a
    # link, so that whatever was typed into other fields is saved instead
    # of being thrown away by a page load: the controller saves the form,
    # then redirects back with this value opened for editing
    # (?issue_form_edit=ID, see #editing_id).
    def edit_button(id)
      @has_controls = true
      form_button(
        view.sprite_icon('edit', l(:button_edit), icon_only: true),
        name: 'issue_form[open]', value: id, class: 'icon-only icon-edit issue-form-edit', title: l(:button_edit)
      )
    end

    # "Cancel" next to a value opened with the pencil: closes it unchanged
    # (the controller drops this field from what it saves), and saves the
    # other fields, for the same reason as #edit_button.
    def cancel_button(id, entry)
      return ''.html_safe unless entry && editing_id == id

      ' '.html_safe + form_button(l(:button_cancel), name: 'issue_form[cancel]', value: id, class: 'issue-form-cancel')
    end

    # Every button of the form. data-disable makes rails-ujs (loaded on
    # every Redmine page) disable all of them once the form is submitted,
    # so a double click can't post the same values twice - which for the
    # new row of a table would add the row twice. Without JavaScript the
    # attribute does nothing and the buttons work as usual.
    def form_button(content, name: nil, **options)
      view.button_tag(content, type: 'submit', name: name, data: { disable: true }, **options)
    end

    # What Enter in any input presses. Browsers submit a form on Enter by
    # clicking its first submit button, which could otherwise be a pencil
    # or a Cancel, so an invisible plain save button goes first.
    def default_button
      form_button('', class: 'issue-form-default', tabindex: -1, 'aria-hidden': true)
    end

    # One form around the whole description: every button in it - check
    # marks, pencils, Cancel - submits everything that was typed (see
    # Submission). Wrapping the description instead of using per-row
    # <form> elements keeps the markup valid - a <form> can't sit inside a
    # <tr> - and needs no JavaScript at all. There is no separate "save
    # all" button at the bottom: every list field and every table row has
    # a check mark (see #row_buttons), and any of them, or Enter, saves
    # everything.
    def wrap_in_form(html)
      footer = view.safe_join(template.form_tables.map do |table|
        view.hidden_field_tag("issue_form[layouts][#{Keys.table_id(table.name)}]", form.layout(table), id: nil)
      end)
      # form_tag without a block returns just the opening tag (with the
      # CSRF token), which avoids depending on the view's output buffer.
      # Not id="issue-form": that is core's own issue edit form on the same
      # page, which application.js serializes by that id to refresh the
      # edit form when the status or tracker changes.
      view.form_tag(view.issue_form_values_path(@issue), method: :post, class: 'issue-form', id: 'issue-form-values',
                                                         onsubmit: UNSAVED_TEXT_GUARD) +
        default_button + html + footer + '</form>'.html_safe
    end

    # Template problems and orphaned table values, shown only to people
    # who can fill the form - they are the ones who can fix it.
    def notes_block
      return ''.html_safe unless interactive?

      html = ''.html_safe
      problems = (template.fields + template.tables).filter_map(&:problem)
      @caught_in_tags.each do |index|
        label = @markers[index][2]
        problems << Template::Problem.new(:placeholder_in_link, key: label) if label
      end
      problems.uniq!
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
