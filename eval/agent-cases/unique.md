# title: feat(utils): add a unique(items) helper preserving order
# expect-gate: pass
# acceptance: removes duplicates; preserves first-seen order; empty array returns empty array; does not mutate the input; works for strings and numbers; has unit tests; lint clean

Add a pure, generic utility `unique(items)` to the shared utilities of the
`{{TEST_DIR}}` package. It returns a new array with duplicate values removed,
keeping the first occurrence of each in its original position. It must not mutate
the input. For example `unique([3, 1, 3, 2, 1])` is `[3, 1, 2]`.

Write unit tests covering duplicates, an already-unique array, the empty array,
and confirming the input is not mutated. Keep the existing lint and test suites
green.
