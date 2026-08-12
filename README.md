# Safe Directory Relocator

Safe Directory Relocator is a PowerShell 7 tool for moving large Windows
developer-tool directories to another drive while keeping their original paths
available through NTFS junctions.

It was extracted from a real disk-pressure maintenance workflow. The tool uses
a deliberately cautious sequence: validate every configured path, copy with
`robocopy`, compare directory/file counts and bytes, rename the original, create
the junction, verify it again, and only then remove the temporary original.
The restore command copies data back without deleting the relocated copy.

> [!WARNING]
> Moving live application data can corrupt it. Close every application that may
> write to the configured directories and keep an independent backup. Always run
> `-ValidateOnly` first and inspect every printed source and target.

## Requirements

- Windows 10 or Windows 11
- PowerShell 7 (`pwsh`)
- `robocopy.exe`
- NTFS volumes that support directory junctions

No administrator elevation is normally required when the current user owns the
configured paths, but local policy may differ.

## Quick start

1. Copy [`examples/relocation.example.json`](examples/relocation.example.json)
   to a private location and edit it. Do not commit personal paths or secrets.
2. Close the application that owns the source directories.
3. Run the read-only preflight:

   ```powershell
   pwsh -NoProfile -File ./src/Move-SafeDirectory.ps1 `
     -ConfigPath ./relocation.json -ValidateOnly
   ```

4. If every path is correct, run the migration:

   ```powershell
   pwsh -NoProfile -File ./src/Move-SafeDirectory.ps1 `
     -ConfigPath ./relocation.json
   ```

5. To copy the data back later:

   ```powershell
   pwsh -NoProfile -File ./src/Restore-SafeDirectory.ps1 `
     -ConfigPath ./relocation.json
   ```

The restore command retains the target copy as an additional safety copy. You
may remove it manually only after checking the restored application.

## Configuration

```json
{
  "target_root": "D:\\RelocatedDeveloperData",
  "items": [
    {
      "name": "example-cache",
      "source": "%LOCALAPPDATA%\\ExampleTool\\cache",
      "target": "ExampleTool\\cache"
    }
  ]
}
```

- `target_root` must be an absolute path and must not be a drive, user-profile,
  Windows, Program Files, or ProgramData root.
- `source` must be an absolute directory path. Windows `%VARIABLE%` syntax is
  expanded, so `%LOCALAPPDATA%` and similar variables are supported.
- `target` must be relative to `target_root`; rooted paths and `..` traversal are
  rejected.
- Every resolved target must be strictly inside `target_root` and must not
  overlap its source.
- Existing reparse points in a configured path and reparse points inside a source
  tree are rejected so the copy cannot silently escape or omit data.
- A target may already contain a partial copy from an interrupted run. The tool
  does not delete it; `robocopy` completes the copy and verification rejects
  unexpected extra data.

## Safety model

The migration command performs a complete read-only preflight before making any
changes. For each item it then:

1. records source directory, file, and byte counts;
2. copies the source without following junctions;
3. verifies source stability and target counts;
4. renames the source to a uniquely named sibling backup;
5. creates and verifies the junction at the original path;
6. verifies counts through the junction;
7. deletes only the uniquely named backup created by that run.

If junction creation or verification fails, the script removes only the
expected failed junction and moves the original directory back. It never erases
the configured relocation target.

The restore command refuses to proceed unless the source is a junction pointing
to the exact configured target. On copy failure it removes only the partial
restored directory, recreates the verified junction, and leaves the target data
untouched.

## Development

Run the self-contained Windows test suite:

```powershell
pwsh -NoProfile -File ./tests/Run-Tests.ps1
```

The tests create data only below `.test-work`, verify the resolved cleanup path,
and cover dangerous-root rejection, read-only validation, migration, and restore.

## Project status

Version `0.1.0` is an early public release. Feedback about additional Windows
developer-tool layouts is welcome, but application-specific process shutdown or
cache semantics remain the caller's responsibility.

## License

MIT. See [`LICENSE`](LICENSE).
