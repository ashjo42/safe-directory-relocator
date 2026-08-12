# Contributing

Issues and pull requests are welcome.

Before proposing a change:

1. Explain the real Windows path layout or failure mode it addresses.
2. Do not include personal paths, logs with private data, access tokens, or
   application cache contents.
3. Keep destructive behavior narrowly scoped and recoverable.
4. Add or update a test that would fail without the change.
5. Run `pwsh -NoProfile -File ./tests/Run-Tests.ps1` on Windows.

Changes that weaken path containment, junction-target verification, copy
verification, or rollback behavior need a concrete safety justification.
