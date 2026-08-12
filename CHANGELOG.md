# Changelog

All notable changes to this project are documented here.

## 0.1.0 - 2026-08-12

- Add JSON-configured directory migration with a read-only validation mode.
- Add file, directory, byte-count, source-stability, and junction verification.
- Add rollback when junction creation or post-link verification fails.
- Add reversible restoration that retains the relocated target copy.
- Add Windows tests and GitHub Actions validation.
