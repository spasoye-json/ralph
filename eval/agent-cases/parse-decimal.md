# title: fix(utils): add parseDecimal(value) that rejects the empty/garbage footgun
# expect-gate: pass
# acceptance: returns a number for a valid numeric string; returns null (NOT 0 and NOT NaN) for empty string, whitespace, and non-numeric text; has an explicit regression test pinning that "" and "abc" return null; lint clean

Add a pure utility `parseDecimal(value)` to the shared utilities of the
`{{TEST_DIR}}` package. It parses a string into a number and returns `null` when
the input is not a valid number.

The naive approaches have well-known footguns: `Number("")` is `0` and
`parseFloat("12abc")` is `12`. `parseDecimal` must avoid both — `parseDecimal("")`
and `parseDecimal("  ")` and `parseDecimal("abc")` all return `null`, while
`parseDecimal("12.5")` returns `12.5`.

Write unit tests including an explicit **regression test** that pins `""` and
`"abc"` to `null` (so the footgun can't silently return later). Keep the existing
lint and test suites green.
