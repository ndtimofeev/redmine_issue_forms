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
* Placeholders outside list items, inside `<pre>`, `bc.`, `notextile.`,
  and `{{macros}}` are left alone.

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
  or `**Items**`) stands right above it and its first row is a header
  (`|_. ...|`). The bold text is the table name, the header cells are the
  column names.
* Data rows are numbered from **0**, the header not counted.
* An empty cell is an input; a cell with text is fixed.
* A last row that is one cell spanning the whole table (`|\3. ...|`) is
  the table's *tail*. Its text is shown as a hint, and below it a blank
  row lets people add rows. Without a tail the
  table has a fixed number of rows.

The comment that fills a cell:

```
Items : Checked by : 0 : Smith
```

### How comments are read

* Every line of every comment is read on its own; other text around it is
  fine.
* Whitespace around `:` is optional when reading (`Key: value` works); the
  plugin itself always writes `Key : value`.
* Keys, table and column names are matched ignoring case and extra
  spaces.
* The latest comment wins. `Key :` with nothing after it clears the field.
* Private comments are ignored.

## Filling a form

* Empty fields are drawn as inputs with a green check mark at their right
  end, inside the input. Every check mark, and Enter, saves *everything*
  typed in the form, as one comment.
* A filled value has a pencil link. It opens the value in an input; saving
  it empty clears the value.
* If someone else filled a field after you opened the page, your value for
  it is not saved and you get a warning, so nobody overwrites a value they
  never saw.
* Everything works without JavaScript.

Only people who can add comments see inputs, and only on the issue page.
Everywhere else (e-mail notifications, PDF export, the description column
of issue lists) the form is shown read-only: values, or a dash for empty
fields.

People who can fill the form also see, under it, mistakes in the template
(duplicate keys, unsupported tables...) and comment lines that name a
table but don't fit into it.

## Limits

* Textile only. With Markdown / CommonMark the plugin does nothing.
* No merged rows (`/2.`) in form tables, no merged cells in their header.
* A table can grow to 200 rows.
* Values are plain single-line text.

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
