# title: feat(utils): add a notificationBadgeLabel(count) display helper
# expect-gate: pass
# acceptance: returns "" for 0 or negative; returns the number as a string for 1..99; returns "99+" for counts above 99; has unit tests covering 0, a mid value, exactly 99, and above 99; lint clean

Add a pure display helper `notificationBadgeLabel(count)` to the shared utilities
of the `{{TEST_DIR}}` package — the kind of small presentation function a badge
component renders. Given an unread count it returns the text to show on the badge:
an empty string for `0` or negative counts (the badge is hidden), the count itself
for `1` through `99`, and `"99+"` for anything above `99`.

Write unit tests covering `0`, a typical value, exactly `99`, and a value above
`99`. Keep the existing lint and test suites green.
