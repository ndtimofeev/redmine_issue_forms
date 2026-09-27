require 'digest'

module RedmineIssueForms
  # How keys are compared, and how fields/cells get their HTML ids.
  #
  # Keys are compared *normalized*: surrounding whitespace dropped, runs of
  # whitespace collapsed to a single space, case folded. People type
  # comments by hand too ("паспорт_серия : 4512"), and a value silently
  # not showing up because of a capital letter or a double space would be
  # far more confusing than the (theoretical) inability to have two
  # fields that differ only in case - which Template reports as a
  # duplicate key anyway.
  module Keys
    module_function

    def normalize(text)
      text.to_s.gsub(/[[:space:]]+/, ' ').strip.downcase
    end

    # HTML id (and form parameter name) of a list placeholder. Derived
    # from the key itself rather than from the placeholder's position in
    # the description, so that a page rendered before someone edited the
    # template still posts values to the right field - or to no field at
    # all, which the controller reports, but never to a *different* field
    # that happened to move into the same position.
    def field_id(key)
      "ifv-#{digest('field', normalize(key))}"
    end

    # HTML id / parameter name of an existing table cell, row being the
    # 0-based data row index (see Template::Table).
    def cell_id(table_name, column_name, row)
      "ifv-#{digest('cell', normalize(table_name), normalize(column_name), row.to_s)}"
    end

    # Cells of the blank "new row" under a table's tail. They have no row
    # index on purpose: the index is only assigned by the controller at
    # save time, under a lock, so two people adding a row at the same
    # moment get two different rows instead of overwriting each other.
    def new_cell_id(table_name, column_name)
      "ifv-#{digest('new', normalize(table_name), normalize(column_name))}"
    end

    # Name of the hidden field that carries a form table's layout at render
    # time (see Form#layout).
    def table_id(table_name)
      "ifv-#{digest('table', normalize(table_name))}"
    end

    def digest(*parts)
      Digest::SHA256.hexdigest(parts.join("\u0000"))[0, 16]
    end
  end
end
