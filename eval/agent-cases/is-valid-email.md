# title: feat(utils): add an isValidEmail(value) helper
# expect-gate: pass
# acceptance: accepts a basic local@domain.tld address; rejects missing @, missing domain, leading/trailing whitespace, and empty string; returns a boolean; has unit tests for accept and reject cases; lint clean

Add a pure utility `isValidEmail(value)` to the shared utilities of the
`{{TEST_DIR}}` package. It returns `true` for a basic, well-formed email address
(`local@domain.tld`) and `false` otherwise. It need not be RFC-exhaustive, but it
must reject a missing `@`, a missing domain or TLD, surrounding whitespace, and
the empty string.

Write unit tests covering at least one valid address and several distinct invalid
cases. Keep the existing lint and test suites green.
