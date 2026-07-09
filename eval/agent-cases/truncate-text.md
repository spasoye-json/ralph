# title: feat(utils): add a truncate(text, max) helper with ellipsis
# expect-gate: pass
# acceptance: returns text unchanged when <= max; truncates and appends a single ellipsis char when longer; never returns a string longer than max; handles empty string; has unit tests; lint clean

Add a pure utility `truncate(text, max)` to the shared utilities of the
`{{TEST_DIR}}` package. When `text.length <= max` it returns `text` unchanged.
When longer, it returns the text cut to fit with a trailing ellipsis ("…") such
that the returned string length never exceeds `max`. An empty string returns an
empty string.

Write unit tests for the unchanged, truncated, exact-boundary, and empty-input
cases. Keep the existing lint and test suites green.
