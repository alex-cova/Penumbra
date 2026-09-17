; Tagged template literals infer a language from the tag (css`...`, html`...`, sql`...`).
(call_expression
  function: [
    (identifier) @injection.language
    (member_expression
      property: (property_identifier) @injection.language)
  ]
  arguments: (template_string) @injection.content)
