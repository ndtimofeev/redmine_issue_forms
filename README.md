# Issue Forms for Redmine

Turns an issue description into a fill-in form. The description is the
template: placeholders in lists and named tables become input fields. What
people type is saved as an ordinary issue comment (`Key : value`), and the
description shows the values from the comments in place of the fields.

There is no separate storage: the comments *are* the data. Editing or
deleting a comment changes the form, the issue history shows who filled
what and when, and e-mail notifications, permissions and the REST API work
exactly as for any other comment.

Requires Redmine 6.0 or later and the **Textile** text formatting.

## Installation

```
cd redmine/plugins
git clone https://github.com/ndtimofeev/redmine_issue_forms.git
# restart Redmine
```

No migrations, no database tables of its own.

Then:

1. *Administration → Plugins → Issue Forms → Configure*: tick the trackers
   whose issues are forms.
2. *Project → Settings → Modules*: enable **Issue forms**.

Anyone who can add comments to an issue can fill its form. There is no
separate permission.

## Writing a form

### Fields in lists

```
* Supplier
** Name: {}
** Tax ID: {}
* Date received: {}
* Responsible: {Resp}
```

* `{}` inside a list item is a field. Its key is built from the item
  labels of every list level, joined with `_`. The label of an item is its
  text before the first `:` (or its whole text without the placeholder
  when there is no colon). Above: `Supplier_Name`, `Supplier_Tax ID`,
  `Date received`.
* `{Key}` gives the field an explicit key (`Resp`). Needed when an item
  has more than one field, and handy for keeping keys short.
* Placeholders outside list items, inside `<pre>`, `<code>`, `<kbd>` and
  `<notextile>` (on one line or across lines; lowercase, as Redmine shows
  `<CODE>` as text) and in quotes (`> ...`) are left alone, and so are the double braces of `{{macros}}`. Redmine's
  Textile has no `bc.` or `notextile.` blocks: a list after them is a
  list, and its placeholders are fields.
* A list, like in Textile, goes on until a blank line or a quote: a line
  of text under an item belongs to that item, and the items after it are
  still nested under the same parents.
* A key or table name can't start with `>`: its comment line would be a
  quote. The template problems (see below) point such keys out.

The comment that fills a field:

```
Supplier_Name : ACME Ltd
```

### Tables

```
*Items*

|_. Item |_. Qty |_. Checked by |
| Bolt M6 | 100 |  |
| Nut M6  |     |  |
|\3. Add more items if the batch has anything else |
```

* A table is a form when a paragraph of nothing but bold text (`*Items*`
  or `**Items**`) stands right above it, its first row is a header
  (`|_. ...|`) and it has something to fill: an empty cell or a tail (see
  below). The bold text is the table name, the header cells are the column
  names. Any other table is an ordinary table, left exactly as Redmine
  shows it.
* Data rows are numbered from **0**, the header not counted.
* An empty cell is an input; a cell with text is fixed.
* A last row that is one cell spanning the whole table (`|\3. ...|`) is
  the table's *tail*. Its text is shown as a hint (an empty tail, `|\3. |`,
  shows nothing), and below it a blank row lets people add rows. Without a
  tail the table has a fixed number of rows.
* A form table can't be sorted by clicking its column headers, as other
  wiki tables with a header can: its rows are addressed by number.

The comment that fills a cell:

```
Items : Checked by : 0 : Smith
```

### How comments are read

* Every line of every comment is read on its own; other text around it is
  fine. Quoted lines (`> ...`) are skipped.
* The colon needs a space before it: `Key : value`, the way the plugin
  itself writes it (`Key :` with nothing after it, at the end of a line,
  clears the field).
  `Key: value` is ordinary prose, so a comment like "Result: all fine"
  never fills a field by accident. A value may contain colons
  (`Items : Time : 0 : 10:30`).
* Keys, table and column names are matched ignoring case and extra
  spaces.
* The latest comment wins. `Key :` with nothing after it clears the field.
* Private comments are ignored.

## Filling a form

* Empty fields are drawn as inputs with a green check mark at their right
  end, inside the input; a table row has one check mark, in its last
  input. Every check mark, and Enter, saves *everything* typed in the
  form, as one comment.
* A filled value has a pencil. It saves whatever was typed elsewhere in
  the form and opens the value in an input; saving it empty clears the
  value. *Cancel* closes it unchanged.
* If someone else changed a field after you opened the page, your value
  for it is not saved, so nobody overwrites a value they never saw. The
  warning repeats what you typed, so nothing has to be retyped from
  memory. The same goes for fields that no longer exist, and for rows
  added to a table that is full.
* Everything works without JavaScript. With it, buttons can't be pressed
  twice, and Redmine's "unsaved text" warning also covers the form: saving
  it while a note is half typed in the *Edit* panel asks first.
* Editing or deleting a comment that holds form values reloads the page,
  so the form shows what is true now (unless something is typed on the
  page: then a note asks to reload).

Only people who can add comments see inputs, and only on the issue page.
Everywhere else (HTML e-mail notifications, PDF export, Atom feeds, the
description column of issue lists) the form is shown read-only: values,
or a dash for empty fields.

People who can fill the form also see, under it, mistakes in the template
(duplicate keys, unsupported tables...) and, as *Values that don't fit the
form*, comment lines that can't be placed: a cell that doesn't exist in a
table, or a value whose field or table an earlier version of the
description had (a label was renamed after the form was filled; the
issue history tells, however long ago it was). A key the form never had is taken for ordinary
prose and not listed. As with values, the latest line for a place wins,
and `Key :` removes it from the list.

## Limits

* Textile only. With Markdown / CommonMark the plugin does nothing (the
  plugin settings page says so).
* Table rows are addressed by number. Inserting or removing a row in the
  template moves the values below it to other rows; do it before a form is
  filled. (A value typed on a page opened before such a change is refused
  as "moved", not written to the wrong row.)
* No merged rows (`/2.`) in form tables, no merged cells in their header.
* A table can grow to 200 rows (fewer for very wide tables).
* Values are plain single-line text.
* The plain-text part of e-mail notifications shows the description as
  written, with its `{}`; the HTML part shows the values.

## Upgrading

The first versions (up to commit `50c6428`, September 2026) made some keys
differently. A value saved under such a key is not shown any more; enter
it again (the old comment stays in the issue history):

* `Key: value` without a space before the colon is ordinary text, not a
  value.
* A line of text under a list item belongs to that item, so the items
  after it keep their parents' labels in their keys.
* Text in angle brackets is part of a label: `* Gap <0.5 mm (spec >0.1): {}`
  was the key `Gap 0.1)`, now it is `Gap <0.5 mm (spec >0.1)`.
* A quote (`> ...`) ends a list: items after it don't get the labels of
  the items above it.
* A placeholder in `<code>`, `<pre>`, `<kbd>` or `<notextile>` on one line
  is not a field.

## Development

```
cd redmine
bin/rails redmine:plugins:test NAME=redmine_issue_forms
```

How it works, in one paragraph: `ApplicationHelper#textilizable` is
prepended (`lib/redmine_issue_forms/application_helper_patch.rb`). For a
form issue's description, `Renderer` replaces every placeholder and form
cell in the Textile source with a unique marker word, lets core render the
text as usual, then swaps the markers for HTML. `Template` parses the
source, `Form` applies the comments to it, `Submission` turns a posted
form into comment lines, and `IssueFormValuesController` saves them under
a row lock on the issue.
