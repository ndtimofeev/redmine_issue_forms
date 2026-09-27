# One endpoint: save typed values of a form issue as one new comment. See
# IssueFormValuesController.
post 'issues/:id/form_values', to: 'issue_form_values#create', as: 'issue_form_values'
