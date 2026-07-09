# title: feat(utils): add a slugify(text) helper
# expect-gate: pass
# acceptance: lowercases; replaces runs of non-alphanumeric chars with a single hyphen; trims leading/trailing hyphens; collapses repeated hyphens; empty string returns empty; has unit tests; lint clean

Add a pure utility `slugify(text)` to the shared utilities of the `{{TEST_DIR}}`
package. It returns a URL-friendly slug: lowercase, with each run of
non-alphanumeric characters replaced by a single hyphen and no leading, trailing,
or repeated hyphens. For example `slugify("  Hello, World!  ")` is `"hello-world"`
and `slugify("")` is `""`.

Write unit tests covering a normal phrase, leading/trailing punctuation, repeated
separators, and the empty string. Keep the existing lint and test suites green.
