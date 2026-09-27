module RedmineIssueForms
  # Turns what the browser posted into the lines of one new comment.
  #
  # Kept apart from the controller so the rules can be unit tested without
  # HTTP, and so the controller can run it against a Form built *inside*
  # its row lock (see IssueFormValuesController#create).
  #
  # Every save button in the form submits the whole form, so the posted
  # values are "everything that was typed anywhere". The rules:
  #
  # * an ordinary (empty) input with nothing typed in it is skipped;
  # * an ordinary input for a target that meanwhile got a value from
  #   someone else is NOT overwritten - it's reported as a conflict,
  #   because the person typing never saw that value;
  # * an input opened with the pencil ("edit" mode, listed in +edited_ids+)
  #   may overwrite, and may clear the value by being left empty - unless
  #   the value changed after the page was rendered (its journal is newer
  #   than +seen_journal_id+), which is again a conflict;
  # * the cells of a table's blank "new row" become one new row, whose
  #   index is only chosen here, so two people adding a row at once get
  #   two rows;
  # * an id the form doesn't know (the template was edited after the page
  #   was rendered) is reported as stale, but only if something was typed.
  class Submission
    attr_reader :lines, :conflicts, :stale, :anchor, :full_tables

    # +values+: {html_id => typed text}, +edited_ids+: ids of inputs opened
    # in edit mode, +seen_journal_id+: Form#last_journal_id at render time.
    def initialize(form, values, edited_ids: [], seen_journal_id: nil)
      @form = form
      @values = (values || {}).to_h { |id, value| [id.to_s, clean(value)] }
      @edited = Array(edited_ids).map(&:to_s)
      @seen = seen_journal_id.to_i
      @lines = []
      @conflicts = []
      @stale = []
      @full_tables = []
      @anchor = nil
      build
    end

    def any?
      lines.any?
    end

    def note
      lines.join("\n")
    end

    # One line, no control characters: a value can never spill into a
    # second line of the comment and turn into another key.
    def clean(value)
      value.to_s.gsub(/[[:cntrl:]  ]+/, ' ').strip
    end

    private

    def build
      targets = @form.targets
      new_rows = {} # table => {column => value}, in template order

      targets.each_value do |target|
        next unless @values.key?(target.id)

        value = @values[target.id]
        if target.kind == :new_cell
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

    def write_existing(target, value)
      current = @form.value_for(target)

      if @edited.include?(target.id)
        return if current.nil? ? value.empty? : current.value == value

        if current && current.journal_id > @seen
          @conflicts << target
          return
        end
      else
        return if value.empty?

        if current
          @conflicts << target unless current.value == value
          return
        end
      end

      add_line(@form.note_line(target, value), target.id)
    end

    def write_new_row(table, cells)
      unless @form.can_add_row?(table)
        @full_tables << table
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
