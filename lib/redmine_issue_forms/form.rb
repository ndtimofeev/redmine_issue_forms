module RedmineIssueForms
  # A Template plus the values its issue's comments assign to it.
  #
  # The single source of truth for a value is the current text of the
  # issue's journal notes - exactly like redmine-custom-decrement-field
  # derives its counter. Nothing is stored anywhere else, so editing or
  # deleting a comment changes the form the next time it is rendered, and
  # there is nothing that can drift out of sync.
  #
  # Reading rules (see #apply_line):
  # * every line of every public note is looked at on its own; other text
  #   in the same comment is simply ignored;
  # * "Key : value" sets a list field, "Table : Column : row : value" a
  #   table cell; whitespace around ":" is optional when reading, although
  #   the plugin itself always writes " : ";
  # * notes are read oldest first, so the last value wins; "Key :" with
  #   nothing after it clears the field again;
  # * private notes are ignored, otherwise people with different
  #   permissions would see different forms.
  class Form
    Entry = Struct.new(:value, :journal_id)

    # A comment line that is clearly aimed at a form table (it starts with
    # the name of one) but can't be placed in it. List keys can't produce
    # orphans: "Something : text" is an everyday sentence in a comment, so
    # a line whose key isn't in the template is just ignored.
    Orphan = Struct.new(:line, :journal_id, :reason)

    # Something a value can be written to. +kind+ is :field, :cell (an
    # existing row) or :new_cell (a cell of the blank row that adds a new
    # row, see Keys.new_cell_id).
    Target = Struct.new(:id, :kind, :field, :table, :column, :row, keyword_init: true)

    SEPARATOR = /[[:blank:]]*:[[:blank:]]*/

    def self.for_issue(issue)
      new(Template.parse(issue.description), notes_for(issue))
    end

    # [[journal_id, notes], ...] of the issue's public, non-empty notes,
    # oldest first. One query; the renderer only runs it once it knows the
    # description actually contains a form.
    def self.notes_for(issue)
      return [] if issue.new_record?

      Journal.where(journalized_type: 'Issue', journalized_id: issue.id, private_notes: false)
             .where.not(notes: [nil, ''])
             .order(:id)
             .pluck(:id, :notes)
    end

    attr_reader :template, :orphans

    # +notes+: [[journal_id, text], ...] ordered oldest first.
    def initialize(template, notes)
      @template = template
      @field_values = {}
      @cell_values = {}
      @orphans = []
      @last_journal_id = 0
      notes.each do |journal_id, text|
        @last_journal_id = journal_id if journal_id > @last_journal_id
        text.to_s.each_line { |line| apply_line(line.strip, journal_id) }
      end
    end

    # Highest id among the notes that were read. The renderer puts it in
    # the form so the controller can tell whether a value that is being
    # *edited* changed after the page was rendered.
    attr_reader :last_journal_id

    def field_value(field)
      @field_values[field.normalized_key]
    end

    def cell_value(table, column, row)
      @cell_values[[table.normalized_name, column, row]]
    end

    def value_for(target)
      case target.kind
      when :field then field_value(target.field)
      when :cell then cell_value(target.table, target.column, target.row)
      end
    end

    # How many data rows +table+ shows: its template rows plus, for a table
    # with a tail, every row a comment has written to.
    def row_count(table)
      return table.template_row_count unless table.tail?

      used = @cell_values.keys.select { |name, _, _| name == table.normalized_name }.map(&:last)
      [table.template_row_count, (used.max || -1) + 1].max
    end

    # The index a new row gets. Always right after the last displayed row,
    # so rows appear in the order they were added.
    def next_row_index(table)
      row_count(table)
    end

    def can_add_row?(table)
      table.tail? && next_row_index(table) < MAX_TABLE_ROWS
    end

    # Every place a value can currently be written to, keyed by HTML id, in
    # template order.
    def targets
      @targets ||= build_targets
    end

    # The exact line to put in a comment to give +target+ +value+ (an empty
    # value produces "Key :", which clears it). +row+ is required for
    # :new_cell targets and ignored otherwise.
    def note_line(target, value, row: nil)
      prefix =
        case target.kind
        when :field
          target.field.key
        else
          table = target.table
          "#{table.name} : #{table.columns[target.column]} : #{target.kind == :new_cell ? row : target.row}"
        end
      "#{prefix} : #{value}".rstrip
    end

    # How a target is named to people: the start of its comment line,
    # "Passport_Series" or "Acceptance : Qty : 1".
    def target_label(target)
      note_line(target, '', row: target.row).delete_suffix(' :')
    end

    def cell_target(table, column, row)
      targets[Keys.cell_id(table.name, table.columns[column], row)]
    end

    private

    def build_targets
      result = {}
      template.valid_fields.each do |field|
        result[field.id] = Target.new(id: field.id, kind: :field, field: field)
      end

      template.form_tables.each do |table|
        row_count(table).times do |row|
          table.columns.each_with_index do |column_name, column|
            if row < table.template_row_count
              cell = table.rows[row].cell_at(column)
              next unless cell&.input?
            end
            id = Keys.cell_id(table.name, column_name, row)
            result[id] = Target.new(id: id, kind: :cell, table: table, column: column, row: row)
          end
        end
        # Known even when the table is full, so that a new row posted just
        # as the table filled up is reported as "table full" rather than as
        # values for fields that don't exist (see Submission).
        next unless table.tail?

        table.columns.each_with_index do |column_name, column|
          id = Keys.new_cell_id(table.name, column_name)
          result[id] = Target.new(id: id, kind: :new_cell, table: table, column: column)
        end
      end
      result
    end

    def apply_line(line, journal_id)
      return if line.empty?

      parts = line.split(SEPARATOR, 4)
      return if parts.size < 2

      # Checked first: a list key can never be equal to a table name (see
      # Template#validate), so "Name : ..." is either a table line or
      # nothing.
      if (table = template.table_named(parts[0]))
        apply_table_line(table, parts, line, journal_id)
        return
      end

      key, value = line.split(SEPARATOR, 2)
      field = template.field_for_key(key)
      return unless field

      store(@field_values, field.normalized_key, value.to_s.strip, journal_id)
    end

    def apply_table_line(table, parts, line, journal_id)
      # "Acceptance : done" is an ordinary sentence that merely starts with
      # a table's name - not an attempt to address a cell.
      return if parts.size < 3

      unless parts.size == 4 && parts[2].match?(/\A\d+\z/)
        # "Table : Column : something" that isn't a cell address - most
        # likely a typo in a hand-written comment.
        @orphans << Orphan.new(line, journal_id, :bad_cell_address)
        return
      end

      column = table.column_index(parts[1])
      row = parts[2].to_i
      reason =
        if column.nil?
          :unknown_column
        elsif row < table.template_row_count
          :static_cell unless table.rows[row].cell_at(column)&.input?
        elsif !table.tail?
          :no_such_row
        elsif row >= MAX_TABLE_ROWS
          :row_limit
        end

      if reason
        @orphans << Orphan.new(line, journal_id, reason)
        return
      end

      store(@cell_values, [table.normalized_name, column, row], parts[3].strip, journal_id)
    end

    def store(hash, key, value, journal_id)
      if value.empty?
        hash.delete(key)
      else
        hash[key] = Entry.new(value, journal_id)
      end
    end
  end
end
