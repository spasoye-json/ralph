# title: feat(utils): add an initials(name) helper
# expect-gate: pass
# acceptance: returns the uppercased first letter of the first and last word; a single word returns one initial; collapses extra whitespace; empty or whitespace-only input returns empty string; has unit tests; lint clean

Add a pure utility `initials(name)` to the shared utilities of the `{{TEST_DIR}}`
package. It returns the uppercased first letters of the first and last words of
`name` — e.g. `initials("ada lovelace")` is `"AL"`, `initials("Ada")` is `"A"`,
and `initials("  ")` is `""`. Ignore extra internal whitespace.

Write unit tests covering a two-word name, a single-word name, extra whitespace,
and empty/whitespace-only input. Keep the existing lint and test suites green.
