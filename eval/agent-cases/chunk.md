# title: feat(utils): add a chunk(items, size) helper
# expect-gate: pass
# acceptance: splits into sub-arrays of length size; the final chunk holds the remainder; empty input returns empty array; a size <= 0 throws or returns empty (pick one, document it, and test it); does not mutate input; has unit tests; lint clean

Add a pure, generic utility `chunk(items, size)` to the shared utilities of the
`{{TEST_DIR}}` package. It splits `items` into consecutive sub-arrays of length
`size`, with the last sub-array holding any remainder. For example
`chunk([1,2,3,4,5], 2)` is `[[1,2],[3,4],[5]]`.

Decide and document the behaviour for a non-positive `size` (throw, or return an
empty array) and test whichever you choose. Write unit tests covering an even
split, an uneven split, the empty input, and the non-positive size. Keep the
existing lint and test suites green.
