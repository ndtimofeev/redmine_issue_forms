require File.expand_path('../test_helper', __dir__)

class RedmineIssueForms::TemplateTest < ActiveSupport::TestCase
  Template = RedmineIssueForms::Template

  def parse(text)
    Template.parse(text)
  end

  test 'auto key joins the labels of the list levels with an underscore' do
    template = parse(<<~T)
      * Passport
      ** Series: {} (no spaces)
      ** Number : {}
      * Date: {}
    T
    assert_equal ['Passport_Series', 'Passport_Number', 'Date'], template.fields.map(&:key)
    assert template.fields.all?(&:valid?)
  end

  test 'label without a colon is the item text without the placeholder' do
    template = parse("* Text text\n** Text text {} text\n")
    assert_equal ['Text text_Text text text'], template.fields.map(&:key)
  end

  test 'explicit key' do
    template = parse("* Owner: {Resp}\n")
    assert_equal ['Resp'], template.fields.map(&:key)
  end

  test 'labels keep going across numbered and mixed lists and reset between lists' do
    template = parse("# First\n#* Sub {}\n\n* Other {}\n")
    assert_equal ['First_Sub', 'Other'], template.fields.map(&:key)
  end

  test 'surrounding emphasis is removed from labels' do
    template = parse("* *Passport*\n** _Series_: {}\n")
    assert_equal ['Passport_Series'], template.fields.map(&:key)
  end

  test 'placeholders outside list items, macros and styles are left alone' do
    template = parse(<<~T)
      Plain {} text
      * {{toc}}
      * %{color:red}styled% and !{width:10px}image.png!
      * style {color:red}
    T
    assert_empty template.fields
  end

  test 'placeholders inside multi-line pre, code, kbd and notextile tags are left alone' do
    template = parse(<<~T)
      <pre>
      * In pre {}
      </pre>
      <code>
      * In code {}
      </code>
      <notextile>
      * In notextile {}
      </notextile>
      * Inline <code>x</code>: {}
    T
    assert_equal ['Inline x'], template.fields.map(&:key)
  end

  test 'bc. and notextile. signatures are plain text in Redmine, so lists after them are live' do
    template = parse("bc.. code\n\n* Name: {}\n\nbc. x\n* Other: {}\n")
    assert_equal ['Name', 'Other'], template.fields.map(&:key)
  end

  test 'a continuation line inside a list keeps the label path' do
    template = parse(<<~T)
      * Passport
        issued in the country
      ** Series: {}
         4 digits
      ** Number: {}
      * Abroad
      ** Series: {}
    T
    assert_equal ['Passport_Series', 'Passport_Number', 'Abroad_Series'], template.fields.map(&:key)
    assert template.fields.all?(&:valid?)
  end

  test 'a placeholder on a continuation line belongs to the item' do
    template = parse("* Series:\n  {}\n* Number: {}\n")
    assert_equal ['Series', 'Number'], template.fields.map(&:key)
  end

  test 'a blank line ends the list' do
    template = parse("* Passport\n\n** Series: {}\n")
    assert_equal ['Series'], template.fields.map(&:key)
  end

  test 'colons inside Textile markup do not cut the label' do
    template = parse(<<~T)
      * %{color:red}Series%: {}
      * *{color:blue}Number*: {}
      * "Manual":https://wiki.example.com/doc: {}
      * Humidity, %: {}
    T
    assert_equal ['Series', 'Number', 'Manual', 'Humidity, %'], template.fields.map(&:key)
  end

  test 'several auto placeholders in one item are a problem' do
    template = parse("* Size: {} x {}\n")
    assert_equal 2, template.fields.size
    assert template.fields.none?(&:valid?)
    assert_equal :several_auto_keys, template.fields.first.problem.code
  end

  test 'several explicit placeholders in one item are fine' do
    template = parse("* Size: {Width} x {Height}\n")
    assert_equal ['Width', 'Height'], template.valid_fields.map(&:key)
  end

  test 'duplicate keys, case-insensitively, are a problem' do
    template = parse("* Date: {}\n* date : {}\n")
    assert_equal [:duplicate_key, :duplicate_key], template.fields.map { |f| f.problem&.code }
  end

  test 'placeholder without any label needs an explicit key' do
    template = parse("* {}\n")
    assert_equal :empty_key, template.fields.first.problem.code
  end

  test 'named table with header, rows and tail' do
    template = parse(<<~T)
      *Acceptance*

      |_. Item |_. Qty |_. Checked |
      | Bolt   | 100   |           |
      | Nut    |       |           |
      |\\3. Add rows if needed |
    T
    table = template.form_tables.first
    assert_equal 'Acceptance', table.name
    assert_equal ['Item', 'Qty', 'Checked'], table.columns
    assert_equal 2, table.template_row_count
    assert table.tail?
    assert_equal [false, false, true], table.rows[0].cells.map(&:input?)
    assert_equal [false, true, true], table.rows[1].cells.map(&:input?)
  end

  test 'table without a bold name or without a header is an ordinary table' do
    assert_empty parse("|_. A |_. B |\n| 1 | |\n").tables
    assert_empty parse("*Name*\n\n| A | B |\n| 1 | |\n").tables
    assert_empty parse("Some text\n*Name*\n\n|_. A |_. B |\n").tables
  end

  test 'table without a tail cannot grow' do
    table = parse("**T**\n|_. A |_. B |\n| | |\n").form_tables.first
    assert_not table.tail?
    assert_equal 1, table.template_row_count
  end

  test 'compact cells as inserted by the Table toolbar button' do
    table = parse("*T*\n\n|_.A|_.B|_.C|\n|x|||\n|\\3.Add rows|\n").form_tables.first
    assert_equal ['A', 'B', 'C'], table.columns
    assert table.tail?
    assert_equal [false, true, true], table.rows[0].cells.map(&:input?)
  end

  test 'only a leading underscore makes a header cell' do
    assert_empty parse("*T*\n\n|(my_class). A |_. B |\n").tables
  end

  test 'wiki links with a pipe do not split cells' do
    table = parse("*T*\n\n|_. A |_. B |\n| [[Page|Title]] | |\n").form_tables.first
    assert_equal '[[Page|Title]]', table.rows[0].cells[0].content
    assert table.rows[0].cells[1].input?
  end

  test 'table problems' do
    assert_equal :table_rowspan, parse("*T*\n|_. A |_. B |\n|/2. x | |\n| |\n").tables.first.problem.code
    assert_equal :table_header_colspan, parse("*T*\n|_\\2. A |\n| | |\n").tables.first.problem.code
    assert_equal :table_duplicate_column, parse("*T*\n|_. A |_. a |\n").tables.first.problem.code
    assert_equal :table_row_width, parse("*T*\n|_. A |_. B |_. C |\n| | |\n| | | |\n").tables.first.problem.code
    assert_equal :table_name_colon, parse("*T: 1*\n|_. A |_. B |\n").tables.first.problem.code
    assert_equal :table_column_colon, parse("*T*\n|_. A: 1 |_. B |\n").tables.first.problem.code
  end

  test 'a list key equal to a table name is a problem' do
    template = parse("* Acceptance {}\n\n*Acceptance*\n\n|_. A |_. B |\n")
    assert_equal :key_is_table_name, template.fields.first.problem.code
  end

  test 'duplicate table names are a problem' do
    template = parse("*T*\n|_. A |\n\n*T*\n|_. B |\n")
    assert_equal [:duplicate_table, :duplicate_table], template.tables.map { |t| t.problem&.code }
    assert_empty template.form_tables
  end

  test 'huge labels, deep lists and many placeholders stay fast' do
    [
      "* #{'-+' * 30_000}- {}\n",
      "*#{'*' * 20_000} #{'{} ' * 6000}\n",
      "*#{'-+' * 30_000}-*\n\n|_. A |\n"
    ].each do |text|
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      parse(text)
      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 1.0
    end
  end

  test 'CRLF line endings' do
    template = parse("* Date: {}\r\n* Owner: {}\r\n")
    assert_equal ['Date', 'Owner'], template.fields.map(&:key)
  end
end
