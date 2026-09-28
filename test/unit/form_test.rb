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

  test 'values for keys and tables an earlier template had are orphans' do
    notes = [
      'Pasport_Series : 4512',        # a label was renamed since
      'Old : 1',
      'Old : 2',                      # last one wins
      "Gone : x\nGone :",             # cleared again
      'Remarque : pièce manquante',   # never a key: prose, even on its own
      "Checked.\nRatio 1 : 2 : 3 : 4", # never a table
      'Items : Qty : 0 : 5'           # a table that was renamed
    ].each_with_index.map { |note, i| [i + 1, note] }
    former = ->(_names) { Set['pasport_series', 'old', 'gone', 'items'] }
    f = RedmineIssueForms::Form.new(RedmineIssueForms::Template.parse(TEMPLATE), notes, former_names: former)
    assert_equal ['Pasport_Series : 4512', 'Old : 2', 'Items : Qty : 0 : 5'], f.orphans.map(&:line)
    assert_equal [:unknown_key, :unknown_key, :unknown_table], f.orphans.map(&:reason)

    assert_empty form(notes.map(&:last)).orphans # without a history nothing is taken for a lost value
  end

  test 'orphans of the same cell replace each other' do
    f = form(['Acceptance : Nope : 0 : 5', 'Acceptance : Nope : 0 : 6', 'Acceptance : Gone : 0 : 1', 'Acceptance : Gone : 0 :'])
    assert_equal ['Acceptance : Nope : 0 : 6'], f.orphans.map(&:line)
  end

  test 'former names come from the whole description history' do
    enable_issue_forms
    issue = form_issue("* Pasport\n** Series: {}\n")
    issue.init_journal(User.find(1))
    issue.update!(description: "* Passport\n** Series: {}\n")
    25.times do |i|
      issue.init_journal(User.find(1))
      issue.update!(description: "* Passport\n** Series: {}\n\nEdit #{i}\n")
    end
    add_note(issue, 'Pasport_Series : 4512')
    add_note(issue, 'Remark : prose')
    issue.reload
    f = RedmineIssueForms::Form.new(RedmineIssueForms::Template.parse(issue.description),
                                    RedmineIssueForms::Form.notes_for(issue),
                                    former_names: ->(names) { RedmineIssueForms::Form.former_names_for(issue, names) })
    assert_equal ['Pasport_Series : 4512'], f.orphans.map(&:line)

    # Prose: no version has every word of "remark", so none is parsed.
    RedmineIssueForms::Template.expects(:parse).never
    assert_empty RedmineIssueForms::Form.former_names_for(issue, Set['remark'])
  ensure
    restore_settings
  end

  test 'the history is only asked when orphans are' do
    calls = []
    former = lambda do |names|
      calls << names
      Set['old']
    end
    f = RedmineIssueForms::Form.new(RedmineIssueForms::Template.parse(TEMPLATE),
                                    [[1, "Resp : Ann\nOld : 1\nRemarque : x"]], former_names: former)
    assert_equal 'Ann', f.field_value(field(f, 'Resp')).value
    assert_empty calls
    assert_equal ['Old : 1'], f.orphans.map(&:line)
    assert f.reads_any?
    assert_equal [Set['old', 'remarque']], calls
  end

  test 'values of a table that has nothing to fill any more say so' do
    template = RedmineIssueForms::Template.parse("*Items*\n\n|_. Item |_. Qty |\n| Nut | 7 |\n")
    assert template.plain_table?('items')
    f = RedmineIssueForms::Form.new(template, [[1, "Items : Item : 0 : Bolt\nGone : Qty : 0 : 1"]],
                                    former_names: ->(_names) { Set['items', 'gone'] })
    assert_equal [:table_not_a_form, :unknown_table], f.orphans.map(&:reason)
  end

  test 'only the most recent names are asked about' do
    notes = (1..60).map { |i| [i, "Word#{i} : text"] }
    asked = nil
    f = RedmineIssueForms::Form.new(RedmineIssueForms::Template.parse(TEMPLATE), notes,
                                    former_names: ->(names) { asked = names; Set.new })
    f.orphans
    assert_equal RedmineIssueForms::Form::MAX_FORMER_NAME_CANDIDATES, asked.size
    assert_includes asked, 'word60'
    assert_not_includes asked, 'word1'
  end

  test 'a comment only with a former key is read' do
    f = RedmineIssueForms::Form.new(RedmineIssueForms::Template.parse(TEMPLATE), [[1, 'Old :']],
                                    former_names: ->(_names) { Set['old'] })
    assert f.reads_any? # the clear of an orphan changes what the form shows
    assert_empty f.orphans
    assert_not form(['Remarque : x']).reads_any?
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
