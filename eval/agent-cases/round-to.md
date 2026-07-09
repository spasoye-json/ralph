# title: feat(utils): add a roundTo(value, decimals) helper
# expect-gate: pass
# acceptance: rounds to the given number of decimals; roundTo(1.005, 2) handles the usual float case sanely; 0 decimals rounds to an integer; negative values round correctly; has unit tests; lint clean

Add a pure utility `roundTo(value, decimals)` to the shared utilities of the
`{{TEST_DIR}}` package (place it wherever the existing helpers live and follow the
surrounding conventions). It rounds `value` to `decimals` decimal places and
returns a number — e.g. `roundTo(3.14159, 2)` is `3.14`, `roundTo(2.5, 0)` is `3`,
`roundTo(-2.675, 2)` rounds the magnitude correctly.

Write unit tests covering rounding up, rounding down, zero decimals, and a
negative value. Keep the existing lint and test suites green.
