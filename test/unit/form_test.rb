require File.expand_path('../test_helper', __dir__)

class RedmineIssueForms::FormTest < ActiveSupport::TestCase
  include RedmineIssueForms::TestSetup

  TEMPLATE = <<~T.freeze
    * Passport
    ** Series: {}
    * Owner: {Resp}

    *Acceptance*

    |_. Item |_. Qty |_. Checked |
    | Bolt   | 100   |           |
    |\\3. Add rows |
  T

  def form(notes)
    RedmineIssueForms::Form.new(RedmineIssueForms::Template.parse(TEMPLATE), notes.each_with_index.map { |n, i| [i + 1, n] })
  end

  def field(form, key)
    form.template.field_for_key(key)
  end

  test 'the last value wins and an empty value clears' do
    f = form(['Passport_Series : 1', "Passport_Series : 2\nother text", 'Resp : x', 'Resp :'])
    assert_equal '2', f.field_value(field(f, 'Passport_Series')).value
    assert_equal 2, f.field_value(field(f, 'Passport_Series')).journal_id
    assert_nil f.field_value(field(f, 'Resp'))
  end

  test 'keys are matched ignoring case and extra whitespace' do
    f = form(['passport_series   :  4512 : 7'])
    assert_equal '4512 : 7', f.field_value(field(f, 'Passport_Series')).value
  end

  test 'the colon needs a space before it, so prose is not a value' do
    f = form(['Resp : Ann', "Checked.\nResp: all fine, call at 10:30", 'Acceptance: done at 10:30'])
    assert_equal 'Ann', f.field_value(field(f, 'Resp')).value
    assert_empty f.orphans
  end

  test 'lines that are not form values are ignored' do
    f = form(["Hello : world\nhttp://example.com\n\nAcceptance : done"])
    assert_nil f.field_value(field(f, 'Passport_Series'))
    assert_empty f.orphans
  end

  test 'quoted lines are ignored' do
    f = form(['Resp : Ann', "Ivan wrote:\n> Resp : Bob\n\nAgreed."])
    assert_equal 'Ann', f.field_value(field(f, 'Resp')).value
  end

  test 'values for keys the template no longer has are orphans' do
    f = form([
      'Pasport_Series : 4512',        # a label was renamed since
      'Old : 1',
      'Old : 2',                      # last one wins
      "Gone : x\nGone :",             # cleared again
      "Looked at it.\nNote : later",  # a sentence among other text
      'Items : Qty : 0 : 5'           # a table that was renamed
    ])
    assert_equal ['Pasport_Series : 4512', 'Old : 2', 'Items : Qty : 0 : 5'], f.orphans.map(&:line)
    assert_equal [:unknown_key, :unknown_key, :unknown_table], f.orphans.map(&:reason)
  end

  test 'table cells, extra rows and the next row index' do
    table_name = 'Acceptance'
    f = form(["#{table_name} : Checked : 0 : Ivanov", "acceptance : qty : 3 : 7"])
    table = f.template.form_tables.first
    assert_equal 'Ivanov', f.cell_value(table, 2, 0).value
    assert_equal '7', f.cell_value(table, 1, 3).value
    assert_equal 4, f.row_count(table)
    assert_equal 4, f.next_row_index(table)
  end

  test 'lines aimed at a table that do not fit are orphans' do
    f = form([
      'Acceptance : Nope : 0 : x',
      'Acceptance : Qty : 0 : x',
      'Acceptance : Qty : one : x',
      "Acceptance : Qty : #{RedmineIssueForms::MAX_TABLE_ROWS} : x"
    ])
    assert_equal [:unknown_column, :static_cell, :bad_cell_address, :row_limit], f.orphans.map(&:reason)
  end

  test 'wide tables get fewer rows' do
    columns = (1..100).map { |i| "|_. C#{i} " }.join
    template = RedmineIssueForms::Template.parse("*W*\n\n#{columns}|\n|\\100. tail |\n")
    table = template.form_tables.first
    limit = RedmineIssueForms::MAX_TABLE_CELLS / 100
    f = RedmineIssueForms::Form.new(template, [[1, "W : C1 : #{limit} : x"]])
    assert_equal limit, f.row_limit(table)
    assert_equal [:row_limit], f.orphans.map(&:reason)
  end

  test 'reading a huge comment is linear' do
    template = RedmineIssueForms::Template.parse((1..300).map { |i| "* F#{i}: {}" }.join("\n"))
    [("x : y\n" * 250_000), "a#{' ' * 500_000}b\n", "a#{" \t" * 250_000}:b"].each do |note|
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      RedmineIssueForms::Form.new(template, [[1, note]])
      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 3.0
    end
  end

  test 'layout changes when the rows of a table change' do
    before = form([])
    table = before.template.form_tables.first
    inserted = TEMPLATE.sub("| Bolt   | 100   |           |\n", "| Washer |  |  |\n| Bolt   | 100   |           |\n")
    after = RedmineIssueForms::Form.new(RedmineIssueForms::Template.parse(inserted), [])
    assert_equal before.layout(table), form(['Resp : x']).layout(table)
    assert_not_equal before.layout(table), after.layout(after.template.form_tables.first)
  end

  test 'a table without a tail keeps its size' do
    template = RedmineIssueForms::Template.parse("*T*\n|_. A |_. B |\n| x | |\n")
    f = RedmineIssueForms::Form.new(template, [[1, 'T : B : 5 : y']])
    assert_equal 1, f.row_count(template.form_tables.first)
    assert_equal [:no_such_row], f.orphans.map(&:reason)
    assert_not f.can_add_row?(template.form_tables.first)
  end

  test 'targets and note lines' do
    f = form([])
    kinds = f.targets.values.map(&:kind)
    assert_equal [:field, :field, :cell, :new_cell, :new_cell, :new_cell], kinds
    series = f.targets.values.first
    assert_equal 'Passport_Series : 4512', f.note_line(series, '4512')
    assert_equal 'Passport_Series :', f.note_line(series, '')
    cell = f.targets.values[2]
    assert_equal 'Acceptance : Checked : 0 : ok', f.note_line(cell, 'ok')
  end

  test 'notes are read from public journals only, oldest first' do
    enable_issue_forms
    issue = form_issue("* Date: {}\n")
    add_note(issue, 'Date : 1')
    add_note(issue, 'Date : 2')
    add_note(issue, 'Date : secret', private_notes: true)
    f = RedmineIssueForms::Form.for_issue(issue)
    assert_equal '2', f.field_value(f.template.fields.first).value
  ensure
    restore_settings
  end
end
