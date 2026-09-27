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
  end

  test 'the same value filled meanwhile is neither a conflict nor a new line' do
    s = submit(form([[5, 'Date : same']]), { Keys.field_id('Date') => 'same' })
    assert_empty s.lines
    assert_empty s.conflicts
  end

  test 'edit mode overwrites and clears, unless changed after rendering' do
    f = form([[5, 'Date : old']])
    id = Keys.field_id('Date')
    assert_equal ['Date : new'], submit(f, { id => 'new' }, edited_ids: [id], seen_journal_id: 5).lines
    assert_equal ['Date :'], submit(f, { id => '' }, edited_ids: [id], seen_journal_id: 5).lines
    assert_empty submit(f, { id => 'old' }, edited_ids: [id], seen_journal_id: 5).lines

    stale = submit(f, { id => 'new' }, edited_ids: [id], seen_journal_id: 4)
    assert_empty stale.lines
    assert_equal [id], stale.conflicts.map(&:id)
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

  test 'a full table refuses new rows' do
    f = form([[1, "T : B : #{RedmineIssueForms::MAX_TABLE_ROWS - 1} : y"]])
    s = submit(f, { Keys.new_cell_id('T', 'A') => 'a' })
    assert_empty s.lines
    assert_equal ['T'], s.full_tables.map(&:name)
  end
end
