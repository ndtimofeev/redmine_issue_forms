module RedmineIssueForms
  # Turns what the browser posted into the lines of one new comment.
  #
  # Kept apart from the controller so the rules can be unit tested without
  # HTTP, and so the controller can run it against a Form built *inside*
  # its row lock (see IssueFormValuesController#create).
  #
  # Every button in the form submits the whole form, so the posted values
  # are "everything that was typed anywhere". The rules:
  #
  # * an ordinary (empty) input with nothing typed in it is skipped;
  # * an ordinary input for a target that meanwhile got a value from
  #   someone else is NOT overwritten - it's reported as a conflict,
  #   because the person typing never saw that value;
  # * an input opened with the pencil ("edit" mode) comes with the value it
  #   was showing (+originals+). Left as it was, it writes nothing. Changed
  #   - or emptied, which clears the value - it is written, unless the
  #   value was changed in the meantime by anyone else in any way (a new
  #   value, a clear, an edited or deleted comment), which is again a
  #   conflict;
  # * the cells of a table's blank "new row" become one new row, whose
  #   index is only chosen here, so two people adding a row at once get
  #   two rows;
  # * something typed for a place that doesn't exist any more is reported
  #   as stale: an id the form doesn't know (a key or column was renamed,
  #   the comment that created a row was deleted), or a cell of a table
  #   whose rows changed after the page was rendered (+layouts+, see
  #   Form#layout) - cells are addressed by row number, so after a row was
  #   inserted above, the same number means a different row.
  #
  # Nothing typed is lost silently: the typed text of every rejected value
  # is available (#typed_value, #rejected_row) for the message shown to the
  # person, so they don't have to remember it.
  class Submission
    attr_reader :lines, :conflicts, :stale, :anchor

    # +values+: {html_id => typed text}.
    # +originals+: {html_id => value shown} for inputs opened in edit mode.
    # +layouts+: {Keys.table_id => Form#layout} of the tables at render time.
    def initialize(form, values, originals: {}, layouts: {})
      @form = form
      @values = clean_hash(values)
      @originals = clean_hash(originals)
      @layouts = (layouts || {}).to_h { |id, layout| [id.to_s, layout.to_s] }
      @lines = []
      @conflicts = []
      @stale = []
      @full_rows = {}
      @anchor = nil
      build
    end

    def any?
      lines.any?
    end

    def note
      lines.join("\n")
    end

    # What was typed for +id+ (cleaned, see #clean).
    def typed_value(id)
      @values[id.to_s]
    end

    # Tables whose new row couldn't be added because they are full.
    def full_tables
      @full_rows.keys
    end

    # The values typed into a full table's new row, in column order.
    def rejected_row(table)
      @full_rows.fetch(table, {}).sort.map(&:last)
    end

    # One line, no control characters: a value can never spill into a
    # second line of the comment and turn into another key.
    def clean(value)
      value.to_s.gsub(/[[:cntrl:]  ]+/, ' ').strip
    end

    private

    def clean_hash(hash)
      (hash || {}).to_h { |id, value| [id.to_s, clean(value)] }
    end

    def build
      targets = @form.targets
      new_rows = {} # table => {column => value}, in template order

      targets.each_value do |target|
        next unless @values.key?(target.id)

        value = @values[target.id]
        if moved?(target)
          @stale << target.id unless value.empty?
        elsif target.kind == :new_cell
          (new_rows[target.table] ||= {})[target.column] = value unless value.empty?
        else
          write_existing(target, value)
        end
      end

      new_rows.each { |table, cells| write_new_row(table, cells) }

      @values.each do |id, value|
        @stale << id unless targets.key?(id) || value.empty?
      end
    end

    # A cell whose table got different rows after the page was rendered.
    # A page that posted no layout for the table is taken at its word.
    def moved?(target)
      return false unless target.kind == :cell

      posted = @layouts[Keys.table_id(target.table.name)]
      posted.present? && posted != @form.layout(target.table)
    end

    def write_existing(target, value)
      current = @form.value_for(target)&.value

      if @originals.key?(target.id)
        original = @originals[target.id]
        # Left as it was shown, or already what was typed: nothing to do.
        return if value == original || value == clean(current)

        if clean(current) != original
          @conflicts << target
          return
        end
      else
        return if value.empty?

        if current
          @conflicts << target unless current == value
          return
        end
      end

      add_line(@form.note_line(target, value), target.id)
    end

    def write_new_row(table, cells)
      unless @form.can_add_row?(table)
        @full_rows[table] = cells
        return
      end

      row = @form.next_row_index(table)
      cells.each do |column, value|
        target = Form::Target.new(kind: :new_cell, table: table, column: column)
        add_line(@form.note_line(target, value, row: row), Keys.cell_id(table.name, table.columns[column], row))
      end
    end

    def add_line(line, id)
      @anchor ||= id
      @lines << line
    end
  end
end
