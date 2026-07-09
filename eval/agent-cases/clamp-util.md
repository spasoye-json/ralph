# title: feat(utils): add a clamp(value, min, max) helper
# expect-gate: pass
# acceptance: returns value unchanged when within range; clamps to min when below; clamps to max when above; has unit tests covering all three; lint clean

Add a small pure utility `clamp(value, min, max)` to the shared utilities of the
`{{TEST_DIR}}` package (place it wherever the existing helpers live and follow the
surrounding conventions). It must return `value` when it is within `[min, max]`,
`min` when `value < min`, and `max` when `value > max`.

Write unit tests covering the in-range, below-min, and above-max cases. Keep the
existing lint and test suites green.
