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
  #   in the same comment is simply ignored, and so are quoted lines
  #   ("> ...", what Redmine's Quote button produces);
  # * "Key : value" sets a list field, "Table : Column : row : value" a
  #   table cell. The colon needs whitespace before it (see SEPARATOR), so
  #   "Result: fine" in an ordinary comment is prose, not a value;
  # * notes are read oldest first, so the last value wins; "Key :" with
  #   nothing after it clears the field again;
  # * private notes are ignored, otherwise people with different
  #   permissions would see different forms.
  class Form
    Entry = Struct.new(:value, :journal_id)

    # A comment line that looks like a form value but has no place in the
    # form. Two kinds (see #orphans):
    # * a line that names a form table but can't be placed in it (unknown
    #   column, fixed cell, no such row...);
    # * a value for a key or table that an earlier version of the
    #   description had and the current one doesn't: the description was
    #   edited after the form was filled and a label changed. Shown so
    #   nothing disappears silently (design §8). Only names the issue's
    #   history knows count, so "Remark : missing part" in an ordinary
    #   comment is never listed.
    # Like values, orphans of the same place replace each other: the last
    # line wins and an empty value removes it.
    Orphan = Struct.new(:line, :journal_id, :reason)

    # The last line for a place of the second kind, before the history was
    # asked about its name (see #former_candidates). +sequence+ orders it
    # among all the lines read.
    Candidate = Struct.new(:name, :value, :line, :journal_id, :reason, :sequence)

    # How many different names of the second kind the history is asked
    # about, the most recently used ones. Each costs a word search per
    # earlier version of the description; comments full of made-up
    # "Word : text" lines shouldn't make every look at the issue slow.
    MAX_FORMER_NAME_CANDIDATES = 50

    # Earlier versions of a description are loaded this many at a time, so
    # a long history is never all in memory at once and the search can
    # stop as soon as every name it looks for was found.
    FORMER_BATCH = 20

    # Something a value can be written to. +kind+ is :field, :cell (an
    # existing row) or :new_cell (a cell of the blank row that adds a new
    # row, see Keys.new_cell_id).
    Target = Struct.new(:id, :kind, :field, :table, :column, :row, keyword_init: true)

    # " : " - a colon with whitespace before it and whitespace (or the end
    # of the line) after it, as the plugin itself writes it. The space
    # before the colon is what tells a value from ordinary prose ("Result:
    # fine", "call me at 10:30"), and it lets a value contain colons
    # ("T : Time : 1 : 10:30").
    #
    # (?<!...) and the atomic group keep matching linear: without them a
    # long run of blanks with no colon after it is rescanned from every
    # position in the run.
    SEPARATOR = /(?<![[:blank:]])(?>[[:blank:]]+):(?:[[:blank:]]+|\z)/

    # "Table : Column : 3 : value" - unmistakably a table cell even when no
    # table of that name exists.
    CELL_ROW = /\A\d+\z/

    # The Form the controller saves against. Without former names: they
    # only matter for #orphans and #reads_any?, which saving never asks.
    def self.for_issue(issue)
      new(Template.parse(issue.description), notes_for(issue))
    end

    # Which of +names+ (normalized keys and table names that comment lines
    # use but the current description doesn't have) an earlier version of
    # +issue+'s description had, going by its history: the "description"
    # changes of its journals, newest first.
    #
    # Every version is looked at - a rename is found however long ago it
    # happened - but cheaply: versions are loaded FORMER_BATCH at a time,
    # only a version that contains every word of a name is parsed (see
    # .may_contain_name?), and the search stops once all names are found.
    # Ordinary prose such as "Remark : missing part" is the common case of
    # a name no version has, and it costs a word search per version.
    def self.former_names_for(issue, names)
      wanted = names.to_set
      found = Set.new
      return found if issue.new_record? || wanted.empty?

      ids = JournalDetail.joins(:journal)
                         .where(journals: { journalized_type: 'Issue', journalized_id: issue.id })
                         .where(property: 'attr', prop_key: 'description')
                         .order(id: :desc).pluck(:id)
      ids.each_slice(FORMER_BATCH) do |batch|
        descriptions = JournalDetail.where(id: batch).order(id: :desc).pluck(:old_value).compact.uniq
        descriptions.each do |description|
          pending = wanted - found
          texts = Template.searchable_texts(description)
          next unless pending.any? { |name| may_contain_name?(texts, name) }

          former = Template.parse(description)
          former.valid_fields.each { |field| found << field.normalized_key if pending.include?(field.normalized_key) }
          former.form_tables.each { |table| found << table.normalized_name if pending.include?(table.normalized_name) }
          return found if found.size == wanted.size
        end
      end
      found
    end

    # Whether a description whose Template.searchable_texts are +texts+
    # can possibly have the key or table name +name+: a name is made of the
    # words of its labels (joined by "_" for nested items), so every one
    # of them must appear in it. A quick test that only rules versions
    # out; Template.parse decides.
    def self.may_contain_name?(texts, name)
      name.split(/[_ ]/).all? { |word| word.empty? || texts.any? { |text| text.include?(word) } }
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

    attr_reader :template

    # +notes+: [[journal_id, text], ...] ordered oldest first.
    # +former_names+: a callable that takes a set of normalized names and
    # returns those an earlier version of the template had (see
    # .former_names_for). Only #orphans and #reads_any? need it, so it is
    # called at most once, when one of them is first asked and a comment
    # line names something the template doesn't have - never while the
    # values are read, which every rendering of the description does.
    def initialize(template, notes, former_names: nil)
      @template = template
      @former_names_source = former_names
      @field_values = {}
      @cell_values = {}
      @orphans = {} # place => [Orphan, sequence], last one wins
      @candidates = {} # place => Candidate, last one wins
      @lines_read = 0
      @sequence = 0
      notes.each do |journal_id, text|
        text.to_s.each_line do |line|
          line = line.strip
          apply_line(line, journal_id) unless line.empty?
        end
      end
    end

    # Whether any line of the notes was a value for this form, or an orphan.
    def reads_any?
      @lines_read.positive? || former_candidates.any?
    end

    # Comment lines that look like values but have no place in the form,
    # in the order they were written.
    def orphans
      @orphans_sorted ||= begin
        former = former_candidates.reject { |candidate| candidate.value.strip.empty? }.map do |candidate|
          [Orphan.new(candidate.line, candidate.journal_id, candidate.reason), candidate.sequence]
        end
        (@orphans.values + former).sort_by(&:last).map(&:first)
      end
    end

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
      table.tail? && next_row_index(table) < row_limit(table)
    end

    # Rows a table with a tail may grow to through comments.
    def row_limit(table)
      [MAX_TABLE_ROWS, MAX_TABLE_CELLS / table.columns.size].min
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

    # A fingerprint of the rows a table's cells are numbered by: its header
    # and data rows, as written in the template. The renderer puts it in
    # the form, and Submission refuses cell values if it changed before
    # they were saved: after a row was inserted or removed, "row 1" is a
    # different row.
    def layout(table)
      @layouts ||= {}
      @layouts[table.normalized_name] ||= begin
        rows = [table.header, *table.rows]
        Keys.digest('layout', *rows.map { |row| template.lines[row.line_index].strip })
      end
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

    # Quoted lines ("> Key : value", what Redmine's Quote button makes of
    # an earlier comment) are not values; Template reports keys that would
    # need such a line.
    def value_line?(line)
      !Template::QUOTE_LINE.match?(line) && line.split(SEPARATOR, 2).size == 2
    end

    # The candidates whose name an earlier template had: the last line of
    # each such place, clearing ones ("Old :") included.
    def former_candidates
      @former_candidates ||= begin
        names = @candidates.each_value.map(&:name).uniq.last(MAX_FORMER_NAME_CANDIDATES).to_set
        former = names.empty? || @former_names_source.nil? ? Set.new : @former_names_source.call(names).to_set
        @candidates.each_value.select { |candidate| former.include?(candidate.name) }
      end
    end

    def apply_line(line, journal_id)
      return unless value_line?(line)

      @sequence += 1

      parts = line.split(SEPARATOR, 4)

      # Checked first: a list key can never be equal to a table name (see
      # Template#validate), so "Name : ..." is either a table line or
      # nothing.
      if (table = template.table_named(parts[0]))
        apply_table_line(table, parts, line, journal_id)
        return
      end

      key, value = line.split(SEPARATOR, 2)
      if (field = template.field_for_key(key))
        store(@field_values, field.normalized_key, value.strip, journal_id)
      elsif parts.size == 4 && parts[2].match?(CELL_ROW)
        # Maybe a cell of a table the template had before it was renamed or
        # removed: the history decides, if it's ever asked.
        address = [:cell, *parts[0..2].map { |part| Keys.normalize(part) }]
        add_candidate(address, address[1], parts[3], line, journal_id, :unknown_table)
      else
        # Maybe a value of a key an earlier template had - or just prose.
        name = Keys.normalize(key)
        add_candidate([:key, name], name, value, line, journal_id, :unknown_key)
      end
    end

    # Like #add_orphan, the last line of a place replaces the earlier ones.
    def add_candidate(place, name, value, line, journal_id, reason)
      @candidates.delete(place)
      @candidates[place] = Candidate.new(name, value, line, journal_id, reason, @sequence)
    end

    def apply_table_line(table, parts, line, journal_id)
      # "Acceptance : done" is an ordinary sentence that merely starts with
      # a table's name - not an attempt to address a cell.
      return if parts.size < 3

      unless parts.size == 4 && parts[2].match?(CELL_ROW)
        # "Table : Column : something" that isn't a cell address - most
        # likely a typo in a hand-written comment. Each such line is its
        # own orphan: there is no place it could be replaced at.
        add_orphan([:line, @sequence], line, line, journal_id, :bad_cell_address)
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
        elsif row >= row_limit(table)
          :row_limit
        end

      if reason
        address = [:cell, table.normalized_name, Keys.normalize(parts[1]), parts[2]]
        add_orphan(address, parts[3], line, journal_id, reason)
        return
      end

      store(@cell_values, [table.normalized_name, column, row], parts[3].strip, journal_id)
    end

    # A line that looks like a value for +place+ but has no place in the
    # form. As for real values, the last one wins and an empty +value+
    # clears it: after "Old : 1", "Old : 2" only the latter is listed, and
    # after "Old :" neither.
    def add_orphan(place, value, line, journal_id, reason)
      @lines_read += 1
      @orphans.delete(place)
      @orphans[place] = [Orphan.new(line, journal_id, reason), @sequence] unless value.strip.empty?
    end

    def store(hash, key, value, journal_id)
      @lines_read += 1
      if value.empty?
        hash.delete(key)
      else
        hash[key] = Entry.new(value, journal_id)
      end
    end
  end
end
