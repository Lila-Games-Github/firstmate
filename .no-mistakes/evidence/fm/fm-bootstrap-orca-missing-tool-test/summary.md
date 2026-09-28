# Host environment: /usr/bin/orca present (GNOME screen reader); PID 2571 = systemd user subreaper
| Scenario | Result |
|---|---|
| base e5332db tests/fm-procevent.test.sh | not ok - the listener under test was not reparented away from its session (ppid 2571) |
| target d607d82 tests/fm-procevent.test.sh | all procevent tests passed (incl. new "reparenting check rejects a listener still under its launching shell") |
| 8459c3b-style orca PATH (raw host PATH) vs current code | not ok - backend=orca should require only the Orca-specific missing tool, got: (empty) |
| target d607d82 tests/fm-bootstrap.test.sh | ok - bootstrap: backend=orca gates the Orca CLI without requiring it on the default backend |
