module RedmineIssueForms
  # Parses an issue description (Textile source) into the form it
  # describes: placeholders inside list items (Field) and form tables
  # (Table). Pure Ruby over the source text, no database and no HTML:
  # everything the renderer and the controller need to know about "what
  # fields does this issue have" comes from here.
  #
  # Template syntax, in short (the README has the long version):
  #
  #   * Passport
  #   ** Series: {}            -> field with key "Passport_Series"
  #   * Owner: {Owner}         -> field with explicit key "Owner"
  #
  #   *Acceptance*             -> bold paragraph = name of the table below
  #
  #   |_. Item |_. Qty |       -> header row = column names
  #   | Bolt   |       |       -> data row 0; empty cell = input
  #   |\2. Add rows below |    -> "tail": full-width colspan last row,
  #                               enables adding rows
  #
  # The parser never raises on bad input. Anything it can't make sense of
  # either stays plain text (not a placeholder / not a form table) or is
  # recorded as a Problem on the field or table, which the renderer shows
  # to people who can fill the form so they can fix the template.
  class Template
    # A problem with the template itself, localized by the renderer as
    # :"text_issue_forms_problem_#{code}" with +args+ as interpolations.
    Problem = Struct.new(:code, :args) do
      def initialize(code, args = {})
        super(code, args)
      end
    end

    # A placeholder inside a list item.
    #
    # +key+ is the key exactly as it will be written into comments (the
    # explicit key, or the auto key built from the list labels), +start+
    # and +length+ locate the "{...}" text within line +line_index+.
    class Field
      attr_reader :key, :line_index, :start, :length, :source
      attr_accessor :problem

      def initialize(key:, line_index:, start:, length:, source:, problem: nil)
        @key = key
        @line_index = line_index
        @start = start
        @length = length
        @source = source
        @problem = problem
      end

      def normalized_key
        Keys.normalize(key)
      end

      def id
        Keys.field_id(key)
      end

      def valid?
        problem.nil?
      end
    end

    # One cell of a table row. +prefix+ is the raw Textile cell attribute
    # block including its trailing dot ("_.", "\3.", "{color:red}.") or ""
    # when the cell has none; it is kept verbatim when the renderer
    # rebuilds a row so that styling survives.
    class Cell
      attr_reader :prefix, :content, :column, :span

      def initialize(prefix:, content:, column:, span:, header:, rowspan:)
        @prefix = prefix
        @content = content
        @column = column
        @span = span
        @header = header
        @rowspan = rowspan
      end

      def header?
        @header
      end

      def rowspan?
        @rowspan
      end

      # A template cell becomes an input only when it is empty and covers
      # exactly one column: an empty colspan cell has no single column it
      # could belong to.
      def input?
        content.empty? && span == 1 && !header?
      end
    end

    class Row
      attr_reader :line_index, :cells

      def initialize(line_index:, cells:)
        @line_index = line_index
        @cells = cells
      end

      def width
        cells.sum(&:span)
      end

      def cell_at(column)
        cells.find { |cell| cell.column == column && cell.span == 1 }
      end
    end

    # A named Textile table.
    #
    # +rows+ are the data rows of the template (header and tail excluded),
    # row index 0 being the first row under the header. +tail+ is the
    # full-width colspan last row if there is one - only tables with a
    # tail can grow through comments.
    class Table
      attr_reader :name, :columns, :header, :rows, :tail, :first_line_index, :last_line_index
      attr_accessor :problem

      def initialize(name:, columns:, header:, rows:, tail:, first_line_index:, last_line_index:, problem: nil)
        @name = name
        @columns = columns
        @header = header
        @rows = rows
        @tail = tail
        @first_line_index = first_line_index
        @last_line_index = last_line_index
        @problem = problem
      end

      def normalized_name
        Keys.normalize(name)
      end

      def valid?
        problem.nil?
      end

      def tail?
        !tail.nil?
      end

      def template_row_count
        rows.size
      end

      def column_index(column_name)
        @column_indexes ||= columns.each_with_index.to_h { |column, index| [Keys.normalize(column), index] }
        @column_indexes[Keys.normalize(column_name)]
      end
    end

    # "{}" or "{Key}", but not "{{macro}}", not a Textile span/image
    # style ("%{color:red}", "!{width:50%}img.png!") and not a style
    # attribute - see #placeholder_key.
    PLACEHOLDER = /(?<![{%!])\{([^{}\n]*)\}(?!\})/

    # "*", "**", "#", "*#"... followed by whitespace. The whitespace is what
    # tells a list item ("* Name") apart from a bold paragraph ("*Name*").
    LIST_ITEM = /\A([*#]+)[[:blank:]]+(.*)\z/

    TABLE_ROW = /\A\|.*\|[[:blank:]]*\z/

    # A paragraph made of nothing but bold text: "*Name*" or "**Name**".
    TABLE_NAME = /\A(\*{1,2})(?![[:space:]*])(.+?)(?<![[:space:]*])\1[[:blank:]]*\z/

    # Textile cell modifiers, copied from Redmine's own RedCloth3
    # (lib/redmine/wiki_formatting/textile/redcloth3.rb: A_HLGN ... C and
    # the cell regex in #block_textile_table) so that a cell is a header,
    # a colspan or plain text for the plugin exactly when it is for the
    # renderer: "_" header, "\N" colspan, "/N" rowspan, alignment,
    # (class), {style}, [lang], then "." and an optional single space -
    # "|_.Name|" (what the editor's Table button inserts) is a header too.
    # RedCloth's A_HLGN is "(?:(?:<>|<|>|=|[()]+)+)" and is only ever used
    # as optional ("A_HLGN?"); this is the same thing written without the
    # nested repeat Ruby warns about.
    CELL_A_HLGN_OPT = '(?:<>|<|>|=|[()])*'
    CELL_A_VLGN = '[\-^~]'
    CELL_C_CLAS = '(?:\([^")]+\))'
    CELL_C_LNGE = '(?:\[[a-z\-_]+\])'
    CELL_C_STYL = '(?:\{[^{][^"}]+\})'
    CELL_S_CSPN = '(?:\\\\\d+)'
    CELL_S_RSPN = '(?:/\d+)'
    CELL_A = "(?:#{CELL_A_HLGN_OPT}#{CELL_A_VLGN}?|#{CELL_A_VLGN}?#{CELL_A_HLGN_OPT})".freeze
    CELL_S = "(?:#{CELL_S_CSPN}?#{CELL_S_RSPN}|#{CELL_S_RSPN}?#{CELL_S_CSPN}?)".freeze
    CELL_C = "(?:#{CELL_C_CLAS}?#{CELL_C_STYL}?#{CELL_C_LNGE}?|#{CELL_C_STYL}?#{CELL_C_LNGE}?#{CELL_C_CLAS}?|" \
             "#{CELL_C_LNGE}?#{CELL_C_STYL}?#{CELL_C_CLAS}?)".freeze
    CELL_ATTRIBUTES = /\A(_?#{CELL_S}#{CELL_A}#{CELL_C})\. ?/

    # Regions Redmine's RedCloth3 leaves unformatted (its OFFTAGS). Redmine
    # has no bc./pre./notextile. block signatures - they render as plain
    # paragraph text - so only these tags hide placeholders.
    PRE_OPEN = /<(pre|code|kbd|notextile)\b[^>]*>/i
    PRE_CLOSE = %r{</(pre|code|kbd|notextile)>}i

    # Deeper list markers are not treated as list items: nobody writes a
    # form 20 levels deep, and it bounds the work per line.
    MAX_LIST_DEPTH = 10

    # Longer labels are cut before cleaning - a key is typed by hand in
    # comments, nothing that long is a real label, and it keeps the
    # cleaning linear in the size of the description.
    MAX_LABEL_LENGTH = 200

    def self.parse(text)
      new(text)
    end

    attr_reader :lines, :fields, :tables

    def initialize(text)
      @lines = text.to_s.split(/\r?\n/, -1)
      @fields = []
      @tables = []
      @skipped = code_line_indexes
      parse_tables
      parse_fields
      validate
    end

    # Tables that are forms and have no problem - the only ones the
    # renderer turns into inputs and the only ones comments can fill.
    # Memoized: the template never changes after #initialize (problems are
    # all assigned there), and Form looks these up once per comment line.
    def form_tables
      @form_tables ||= tables.select(&:valid?)
    end

    def valid_fields
      @valid_fields ||= fields.select(&:valid?)
    end

    def empty?
      fields.empty? && tables.empty?
    end

    def table_named(name)
      @tables_by_name ||= form_tables.index_by(&:normalized_name)
      @tables_by_name[Keys.normalize(name)]
    end

    def field_for_key(key)
      @fields_by_key ||= valid_fields.index_by(&:normalized_key)
      @fields_by_key[Keys.normalize(key)]
    end

    private

    # --- code blocks -------------------------------------------------------

    # Line indexes inside a multi-line <pre>, <code>, <kbd> or <notextile>
    # region - what Redmine's RedCloth3 leaves unformatted. A "{}" or a
    # table in there is sample text, not a form, and must be left alone.
    # A tag opened and closed on the same line doesn't hide the line: that
    # is inline code inside ordinary text.
    def code_line_indexes
      skipped = Set.new
      open_tag = false

      lines.each_with_index do |line, index|
        if open_tag
          skipped << index
          open_tag = false if PRE_CLOSE.match?(line)
        elsif (position = line =~ PRE_OPEN)
          unless PRE_CLOSE.match?(line[position..])
            skipped << index
            open_tag = true
          end
        end
      end

      skipped
    end

    def skipped?(index)
      @skipped.include?(index)
    end

    # --- tables ------------------------------------------------------------

    def parse_tables
      index = 0
      while index < lines.size
        if skipped?(index) || !TABLE_ROW.match?(lines[index])
          index += 1
          next
        end

        first = index
        index += 1 while index < lines.size && !skipped?(index) && TABLE_ROW.match?(lines[index])
        table = build_table(first, index - 1)
        @tables << table if table
      end
    end

    # Returns nil for an ordinary (non-form) table: one without a bold
    # name above it, or whose first row isn't a header row. Such tables
    # are none of our business and are not even reported as problems.
    def build_table(first, last)
      name = table_name_above(first)
      return nil unless name

      rows = (first..last).map { |line_index| parse_row(line_index) }
      header = rows.first
      return nil unless header.cells.all?(&:header?)

      columns = header.cells.map { |cell| Template.clean_label(cell.content) }
      body = rows.drop(1)
      tail = nil
      if body.any?
        candidate = body.last
        if candidate.cells.size == 1 && candidate.cells.first.span >= columns.size && columns.size > 1
          tail = candidate
          body = body[0...-1]
        elsif candidate.cells.size == 1 && columns.size == 1 && candidate.cells.first.prefix.include?('\\')
          # A one-column table's tail can only be told apart from an
          # ordinary row by an explicit colspan ("|\1. ... |").
          tail = candidate
          body = body[0...-1]
        end
      end

      table = Table.new(
        name: name, columns: columns, header: header, rows: body, tail: tail,
        first_line_index: first, last_line_index: last
      )
      table.problem = table_problem(table, rows)
      table
    end

    def table_name_above(first)
      index = first - 1
      index -= 1 while index >= 0 && lines[index].strip.empty?
      return nil if index.negative? || skipped?(index)

      m = TABLE_NAME.match(lines[index].strip)
      return nil unless m
      # The bold line has to be a paragraph of its own, not the last line
      # of a longer paragraph.
      return nil if index.positive? && !lines[index - 1].strip.empty?

      Template.clean_label(m[2])
    end

    def table_problem(table, rows)
      return Problem.new(:table_name_colon, table: table.name) if table.name.include?(':')
      return Problem.new(:table_rowspan, table: table.name) if rows.any? { |row| row.cells.any?(&:rowspan?) }
      return Problem.new(:table_header_colspan, table: table.name) if table.header.cells.any? { |cell| cell.span != 1 }

      table.columns.each do |column|
        return Problem.new(:table_empty_column, table: table.name) if column.empty?
        return Problem.new(:table_column_colon, table: table.name, column: column) if column.include?(':')
      end
      counts = table.columns.map { |column| Keys.normalize(column) }.tally
      duplicate = counts.find { |_, count| count > 1 }&.first
      return Problem.new(:table_duplicate_column, table: table.name, column: duplicate) if duplicate

      table.rows.each_with_index do |row, row_index|
        if row.width != table.columns.size
          return Problem.new(:table_row_width, table: table.name, row: row_index)
        end
      end
      nil
    end

    def parse_row(line_index)
      column = 0
      cells = Template.split_cells(lines[line_index]).map do |raw|
        prefix = ''
        content = raw
        if (m = CELL_ATTRIBUTES.match(raw))
          prefix = "#{m[1]}."
          content = raw[m[0].length..]
        end
        span = prefix[/\\(\d+)/, 1].to_i
        span = 1 if span < 1
        cell = Cell.new(
          prefix: prefix, content: content.strip, column: column, span: span,
          header: prefix.start_with?('_'), rowspan: prefix.match?(%r{/\d})
        )
        column += span
        cell
      end
      Row.new(line_index: line_index, cells: cells)
    end

    # --- list fields -------------------------------------------------------

    def parse_fields
      table_lines = Set.new
      tables.each { |table| (table.first_line_index..table.last_line_index).each { |i| table_lines << i } }
      labels = [] # labels of the current item and its ancestors, by level
      item_auto_fields = [] # "{}" fields of the current item, continuation lines included

      lines.each_with_index do |line, index|
        # Textile ends a list only at a blank line (or at something that
        # isn't text at all). A non-bullet line right after an item is a
        # continuation of that item - rendered inside its <li> - so it
        # keeps the label path, and so do the bullets that follow it.
        if line.strip.empty? || skipped?(index) || table_lines.include?(index)
          labels = []
          item_auto_fields = []
          next
        end

        m = LIST_ITEM.match(line)
        if m && m[1].length <= MAX_LIST_DEPTH
          level = m[1].length
          text = m[2]
          offset = m.begin(2)
          labels = labels.first(level - 1)
          labels.fill('', labels.size...(level - 1))
          labels << item_label(text)
          item_auto_fields = []
        elsif labels.any?
          text = line
          offset = 0
        else
          next # ordinary paragraph text: placeholders only count in lists
        end

        collect_placeholders(text, offset, index, auto_key(labels), item_auto_fields)
      end
    end

    # Adds a Field for every placeholder in +text+ (which starts at column
    # +offset+ of line +line_index+). +auto_key+ is computed once per line
    # by the caller - every "{}" of an item gets the same one.
    def collect_placeholders(text, offset, line_index, auto_key, item_auto_fields)
      text.to_enum(:scan, PLACEHOLDER).each do
        match = Regexp.last_match
        key = placeholder_key(match[1])
        next if key == :not_a_placeholder

        field = Field.new(
          key: key || auto_key, line_index: line_index,
          start: offset + match.begin(0), length: match[0].length, source: match[0]
        )
        @fields << field
        next unless key.nil?

        item_auto_fields << field
        if item_auto_fields.size > 1
          item_auto_fields.each { |f| f.problem = Problem.new(:several_auto_keys, key: f.key) }
        end
      end
    end

    # nil for "{}" (auto key), the key for "{Key}", :not_a_placeholder for
    # anything that looks like Textile styling rather than a key: CSS
    # ("{color:red}") always has a ":" or ";", and a "|" would break the
    # table syntax the key may end up in.
    def placeholder_key(content)
      stripped = content.strip
      return nil if stripped.empty?
      return :not_a_placeholder if stripped.match?(/[:;|]/)

      stripped
    end

    # The item's visible text up to the first ":" - Textile markup is taken
    # out first, so a colon inside a style ("%{color:red}Series%: {}") or a
    # link URL ("\"Doc\":https://wiki/x: {}") doesn't cut the label.
    def item_label(text)
      plain = text.gsub(PLACEHOLDER) { |match| placeholder_key(Regexp.last_match(1)) == :not_a_placeholder ? match : '' }
      plain = Template.strip_inline_markup(plain)
      head = plain.include?(':') ? plain.split(':', 2).first : plain
      Template.clean_label(head)
    end

    def auto_key(labels)
      labels.reject(&:empty?).join('_')
    end

    # --- cross checks ------------------------------------------------------

    def validate
      fields.each do |field|
        next unless field.valid?

        if field.key.strip.empty?
          field.problem = Problem.new(:empty_key)
        elsif field.key.include?(':')
          field.problem = Problem.new(:key_colon, key: field.key)
        end
      end

      valid = fields.select(&:valid?)
      valid.group_by(&:normalized_key).each_value do |same|
        next if same.size < 2

        same.each { |field| field.problem = Problem.new(:duplicate_key, key: field.key) }
      end

      tables.select(&:valid?).group_by(&:normalized_name).each_value do |same|
        next if same.size < 2

        same.each { |table| table.problem = Problem.new(:duplicate_table, table: table.name) }
      end

      # A comment line "Name : a : 1 : x" is read as a table cell whenever
      # "Name" is a table, so a list key equal to a table name could never
      # be filled reliably.
      table_names = tables.select(&:valid?).map(&:normalized_name)
      fields.select(&:valid?).each do |field|
        field.problem = Problem.new(:key_is_table_name, key: field.key) if table_names.include?(field.normalized_key)
      end
    end

    public

    # Splits "| a | b |" into [" a ", " b "], not splitting on the "|"
    # inside a Redmine wiki link "[[Page|Title]]".
    def self.split_cells(line)
      body = line.strip
      body = body[1..] if body.start_with?('|')
      body = body[0...-1] if body.end_with?('|')

      cells = []
      buffer = +''
      depth = 0
      index = 0
      while index < body.length
        pair = body[index, 2]
        if pair == '[['
          depth += 1
          buffer << pair
          index += 2
        elsif pair == ']]' && depth.positive?
          depth -= 1
          buffer << pair
          index += 2
        elsif body[index] == '|' && depth.zero?
          cells << buffer
          buffer = +''
          index += 1
        else
          buffer << body[index]
          index += 1
        end
      end
      cells << buffer
    end

    # Plain text of a label: whitespace collapsed, surrounding Textile
    # emphasis ("*bold*", "_italic_", "+ins+", "@code@", "-del-") removed.
    #
    # The text is cut to MAX_LABEL_LENGTH first: each round of the loop
    # rescans the label, so without the cut a huge one-line "label" would
    # make every render of the issue quadratic in its length.
    def self.clean_label(text)
      label = text.to_s[0, MAX_LABEL_LENGTH * 4].gsub(/[[:space:]]+/, ' ').strip[0, MAX_LABEL_LENGTH].strip
      while (m = label.match(/\A([*_+@-]{1,2})(.+?)\1\z/))
        label = m[2].strip
      end
      label
    end

    # Visible text of Textile inline markup that can hide a ":" - links
    # ("text":url, "text(title)":url) become their text, styled spans
    # (%{color:red}text%) their text, style blocks after phrase modifiers
    # (*{color:red}bold*) and inline HTML tags (<code>) disappear.
    def self.strip_inline_markup(text)
      text.gsub(/<[^<>]*>/, '')
          .gsub(/"([^"]+?)(?:\([^()]*\))?":(?:\S*[^\s:])/, '\\1')
          .gsub(/%(?:\{[^{}]*\}|\([^()]*\)|\[[^\[\]]*\])+([^%]*)%/, '\\1')
          .gsub(/\{[^{}]*[:;][^{}]*\}/, '')
    end
  end
end
