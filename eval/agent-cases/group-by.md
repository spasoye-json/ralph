# title: feat(utils): add a groupBy(items, keyFn) helper
# expect-gate: pass
# acceptance: returns an object mapping each computed key to the array of items with that key; preserves item order within each group; empty input returns an empty object; does not mutate input; has unit tests; lint clean

Add a pure, generic utility `groupBy(items, keyFn)` to the shared utilities of the
`{{TEST_DIR}}` package. It returns an object (a record) mapping each key produced
by `keyFn(item)` to the array of items that produced that key, preserving the
original order within each group. For example grouping `[{t:"a",n:1},{t:"b",n:2},
{t:"a",n:3}]` by `item => item.t` yields `{ a: [{t:"a",n:1},{t:"a",n:3}], b:
[{t:"b",n:2}] }`.

Write unit tests covering multiple groups, a single group, and the empty input.
Keep the existing lint and test suites green.
