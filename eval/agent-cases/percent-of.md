# title: feat(utils): add a percentOf(part, total) helper guarding divide-by-zero
# expect-gate: pass
# acceptance: returns part/total * 100; returns 0 when total is 0 (no NaN/Infinity); rounds to a whole percent; clamps nothing (values may exceed 100); has unit tests including the total === 0 case; lint clean

Add a pure utility `percentOf(part, total)` to the shared utilities of the
`{{TEST_DIR}}` package. It returns what percentage `part` is of `total`, as a whole
number — e.g. `percentOf(1, 4)` is `25`. When `total` is `0` it must return `0`
rather than `NaN` or `Infinity`.

Write unit tests covering a normal ratio, a value over 100%, and the
`total === 0` guard. Keep the existing lint and test suites green.
