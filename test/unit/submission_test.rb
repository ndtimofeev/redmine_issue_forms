require File.expand_path('../test_helper', __dir__)

class RedmineIssueForms::SubmissionTest < ActiveSupport::TestCase
  Keys = RedmineIssueForms::Keys

  TEMPLATE = <<~T.freeze
    * Date: {}
    * Owner: {}

    *T*

    |_. A |_. B |
    | x   |     |
    |\\2. |
  T

  def form(notes = [])
    RedmineIssueForms::Form.new(RedmineIssueForms::Template.parse(TEMPLATE), notes)
  end

  def submit(form, values, **options)
    RedmineIssueForms::Submission.new(form, values, **options)
  end

  test 'filled inputs become lines, empty ones are skipped' do
    s = submit(form, { Keys.field_id('Date') => ' 2026-09-27 ', Keys.field_id('Owner') => '' })
    assert_equal ['Date : 2026-09-27'], s.lines
    assert_equal Keys.field_id('Date'), s.anchor
  end

  test 'newlines in a value never produce a second line' do
    s = submit(form, { Keys.field_id('Date') => "1\r\nOwner : evil" })
    assert_equal ['Date : 1 Owner : evil'], s.lines
  end

  test 'a value filled by someone else meanwhile is not overwritten' do
    s = submit(form([[5, 'Date : theirs']]), { Keys.field_id('Date') => 'mine' })
    assert_empty s.lines
    assert_equal [Keys.field_id('Date')], s.conflicts.map(&:id)
    assert_equal 'mine', s.typed_value(Keys.field_id('Date'))
  end

  test 'the same value filled meanwhile is neither a conflict nor a new line' do
    s = submit(form([[5, 'Date : same']]), { Keys.field_id('Date') => 'same' })
    assert_empty s.lines
    assert_empty s.conflicts
  end

  test 'edit mode overwrites and clears, unless changed after rendering' do
    f = form([[5, 'Date : old']])
    id = Keys.field_id('Date')
    assert_equal ['Date : new'], submit(f, { id => 'new' }, originals: { id => 'old' }).lines
    assert_equal ['Date :'], submit(f, { id => '' }, originals: { id => 'old' }).lines
    assert_empty submit(f, { id => 'old' }, originals: { id => 'old' }).lines

    changed = submit(f, { id => 'new' }, originals: { id => 'older' })
    assert_empty changed.lines
    assert_equal [id], changed.conflicts.map(&:id)
  end

  test 'edit mode left untouched never undoes what others did meanwhile' do
    id = Keys.field_id('Date')
    # cleared, edited, deleted (an older value shows again) by someone else
    [[[5, 'Date : old'], [6, 'Date :']], [[5, 'Date : corrected']], [[3, 'Date : older']]].each do |notes|
      s = submit(form(notes), { id => 'old', Keys.field_id('Owner') => 'Ann' }, originals: { id => 'old' })
      assert_equal ['Owner : Ann'], s.lines
      assert_empty s.conflicts
    end
    # but a real change on top of someone else's is a conflict
    s = submit(form([[5, 'Date : old'], [6, 'Date :']]), { id => 'new' }, originals: { id => 'old' })
    assert_empty s.lines
    assert_equal [id], s.conflicts.map(&:id)
  end

  test 'cells of a table whose rows changed after rendering are stale' do
    f = form
    table = f.template.form_tables.first
    cell = Keys.cell_id('T', 'B', 0)
    layouts = { Keys.table_id('T') => f.layout(table) }
    assert_equal ['T : B : 0 : b'], submit(f, { cell => 'b' }, layouts: layouts).lines

    moved = submit(f, { cell => 'b', Keys.new_cell_id('T', 'A') => 'a' }, layouts: { Keys.table_id('T') => 'other' })
    assert_equal ['T : A : 1 : a'], moved.lines
    assert_equal [cell], moved.stale
  end

  test 'new row cells get the next row index' do
    f = form([[1, 'T : B : 1 : y']])
    s = submit(f, { Keys.new_cell_id('T', 'A') => 'a', Keys.new_cell_id('T', 'B') => 'b' })
    assert_equal ['T : A : 2 : a', 'T : B : 2 : b'], s.lines
    assert_equal Keys.cell_id('T', 'A', 2), s.anchor
  end

  test 'an empty new row adds nothing' do
    assert_empty submit(form, { Keys.new_cell_id('T', 'A') => ' ' }).lines
  end

  test 'unknown ids are stale only when something was typed' do
    s = submit(form, { 'ifv-deadbeef' => 'x', 'ifv-cafe' => '' })
    assert_equal ['ifv-deadbeef'], s.stale
  end

  test 'an opened value whose cell moved is stale only if it was changed' do
    f = form([[1, 'T : B : 0 : 100']])
    cell = Keys.cell_id('T', 'B', 0)
    moved = { Keys.table_id('T') => 'other' }
    untouched = submit(f, { cell => '100', Keys.field_id('Owner') => 'Ann' }, originals: { cell => '100' }, layouts: moved)
    assert_equal ['Owner : Ann'], untouched.lines
    assert_empty untouched.stale

    cleared = submit(f, { cell => '' }, originals: { cell => '100' }, layouts: moved)
    assert_equal [cell], cleared.stale
    assert_equal '100', cleared.original_value(cell)

    gone = submit(f, { 'ifv-0000000000000000' => '' }, originals: { 'ifv-0000000000000000' => 'x' })
    assert_equal ['ifv-0000000000000000'], gone.stale
  end

  test 'layout checks stay linear on big tables' do
    rows = (0...1000).map { |i| "| r#{i} |  |  |  |" }.join("\n")
    template = RedmineIssueForms::Template.parse("*Big*\n\n|_. A |_. B |_. C |_. D |\n#{rows}\n")
    f = RedmineIssueForms::Form.new(template, [])
    values = f.targets.keys.to_h { |id| [id, ''] }
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    submit(f, values, layouts: { Keys.table_id('Big') => f.layout(template.form_tables.first) })
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 0.5
  end

  test 'a full table refuses new rows' do
    f = form([[1, "T : B : #{RedmineIssueForms::MAX_TABLE_ROWS - 1} : y"]])
    s = submit(f, { Keys.new_cell_id('T', 'B') => 'b', Keys.new_cell_id('T', 'A') => 'a' })
    assert_empty s.lines
    assert_equal ['T'], s.full_tables.map(&:name)
    assert_equal %w[a b], s.rejected_row(s.full_tables.first)
  end
end
