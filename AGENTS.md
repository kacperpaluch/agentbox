# AGENTS.md

## Project overview

Agentbox is a native macOS 14+ application and CLI written in Swift 6. It manages a shared library of AI skills and MCP server configurations for Claude Code, Codex, and OpenCode.

The application prepares files and directories for those clients. It does not run MCP servers, perform OAuth, or replace the clients themselves.

## Repository map

- `Sources/SkillboxCore/` — models, persistence, imports, rendering, synchronization, local backups and recovery snapshots, and external process execution.
- `Sources/SkillboxApp/` — SwiftUI/AppKit macOS interface.
- `Sources/SkillboxCLI/` — command-line interface.
- `Tests/SkillboxCoreTests/` — integration-style core tests and golden fixtures.
- `Tests/SkillboxAppTests/` — tests for the window's own logic (`AppModel`, `LibraryWatcher`), driving a real service on a temporary library. Never point them at the real one.
- `Resources/` — application metadata and icons.
- `scripts/` — application and DMG build scripts.
- `docs/USER_GUIDE.md` — user-facing behavior and recovery instructions.
- `CHANGELOG.md` — release history in Keep a Changelog format.

## Build and test

Run the full test suite after changing Swift code:

```bash
env CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache" \
  SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache" \
  swift test --disable-sandbox
```

Build the release application with:

```bash
env CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache" \
  SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache" \
  swift build -c release --product AgentboxApp --disable-sandbox
```

Build a distributable image only when requested:

```bash
./scripts/build-dmg.sh
hdiutil verify dist/Agentbox-<version>.dmg
```

The DMG build script removes older local `Agentbox-*.dmg` files before creating the current version. Do not accumulate stale release artifacts in `dist/`.

Do not commit `.build/` or generated `dist/` artifacts. DMG files belong in GitHub Releases unless the user explicitly requests otherwise.

## Architecture rules

- Keep reusable business logic in `SkillboxCore`; do not place persistence or synchronization logic in SwiftUI views.
- `AppModel` owns the order of an action, the reload that follows it and what the user is told; that logic belongs in `Tests/SkillboxAppTests`, not in a view.
- Preserve actor isolation for `SkillboxStore` and `SkillboxService`.
- Keep the core Foundation-based where practical. AppKit-specific code belongs in `SkillboxApp`.
- Prefer small, explicit models over untyped dictionaries except at JSON/TOML serialization boundaries.
- Keep CLI and GUI behavior consistent when they expose the same operation.

## Data compatibility

- Existing MVP libraries must remain readable. The default data directory intentionally retains the legacy name `~/Library/Application Support/Skillbox`.
- Treat changes to `Catalog`, `LocalConfiguration`, `MCPConfiguration`, `DocsConfiguration`, and persisted nested models as schema changes.
- When adding persisted fields, provide backward-compatible decoding through defaults, optionals, or an explicit migration.
- Do not silently discard malformed or unknown user data.
- Preserve atomic writes and create recovery snapshots before mutating library metadata.
- The library has no Git backup. It was removed in 0.18.0; `backups/full/` plus `.agentbox-snapshots/` are the whole recovery story. Do not describe the library as backed up to a remote, and do not reintroduce one without deciding first what must stay out of it — `projects.local.json` describes this Mac only, and `mcp-secrets.json` holds unencrypted secrets.

## Secrets and MCP safety

- `mcp-secrets.json` (written by versions up to 0.18.0) and `mcp.json` are local and excluded from Git, but neither is encrypted. Do not describe either as encrypted or Keychain-backed.
- Never log, commit, or include actual API keys and MCP tokens in fixtures, errors, documentation, or release notes.
- Snapshots and full backups *do* copy `mcp.json`, which since 0.18.0 can hold a token — that is deliberate, because a recovery that dropped the MCP configuration would be no recovery at all. The rule those copies must satisfy is the one above them: 0600 on every copy, 0700 on the directories, and nothing leaves this Mac. Do not write "sekrety nigdy nie trafiają do snapshotów"; it is not true, and pretending otherwise is how the protection stopped being applied in the first place.
- Imported MCP values are classified two ways today: a `${VAR}` value becomes a reference to a system variable, everything else is stored as a local value **inside `mcp.json`**. The separate "local secret" class was dropped in 0.18.0. Do not describe a third option that no longer exists, and do not move values into `mcp-secrets.json` automatically — an automatic decision about what is a secret is exactly what the removed classification existed to avoid.
- Because `mcp.json` can therefore hold a token, it is treated as secret-bearing wherever it is written or copied: 0600 on the file, 0700 on `.agentbox-snapshots/` and `backups/`, and the same on every copy inside them. `Store.restrictIfSensitive` is the single place that decides this; new files that can hold user values belong on its list.
- Treat automatic secret detection as a suggestion, not an authoritative decision.
- Preserve manual MCP entries in project files. A naming conflict with an unmanaged entry must stop synchronization instead of overwriting it.
- Generated project configurations may contain resolved secrets. Maintain `.git/info/exclude` protection and visible warnings, while remembering that already tracked files are not protected by exclude rules.

## Failure handling

These rules exist because a review of 0.24.0 found the same mistake in a dozen places: the codebase has the right rules and applies them unevenly.

- A value read from disk that cannot be parsed is an error, never an empty value. `(try? String(contentsOf:)) ?? ""` turned an unreadable `AGENTS.md` into "this file should not exist" and deleted it.
- Identifiers that arrive from a file — a manifest, an imported configuration — are input, not data Agentbox wrote. Validate them before they reach a path, and refuse the whole operation instead of silently ignoring the bad entry.
- Read and validate everything an operation needs *before* the first destructive step, so a failure halfway leaves nothing behind.
- A failed rollback must be reported together with the error that caused it, and must keep whatever copy it was restoring from. `RollbackReport` is the one implementation of that rule — a new place that undoes a half-finished write uses it rather than its own `try?`.
- Reading one of the user's files in order to rewrite it goes through `SkillboxService.existingText`, which refuses a file it cannot decode. Anything else silently replaces content Agentbox did not understand.
- Paths built from data on disk are checked after symlinks are resolved, not by their spelling. A validated name inside a symlinked directory still lands outside the project.
- A test proves the effect, not the implementation. Asking the same helper that produced the value whether the value is right is how a broken exclude path passed its own test; ask Git, the file system, or the public operation instead.
- `try?` on the app side must never turn a thrown error into a successful-looking result. A UI action that a sheet waits on returns whether it succeeded (`performing`), and the sheet closes only then.

## Synchronization invariants

- Preview must be computed before modifying a project.
- `Synchronizuj wszystko` must remain transactional across skills and MCP files.
- Back up every managed target before replacement and roll back all earlier changes if a later write fails.
- Update manifests only after their corresponding writes succeed.
- Do not ignore file-removal or replacement errors.
- Never delete directories that are not listed in an Agentbox manifest.
- The rollback copy taken before a project write is transient: it lives in a temporary directory and is removed once the operation ends, successfully or not. Agentbox keeps no backup history inside project folders — the library is the source of truth and `unsyncProject` plus a re-sync reproduces any project state.
- Add a regression test whenever synchronization ownership, backup, rollback, or manifest behavior changes.

## Testing expectations

- Add or update tests for every change to parsing, persisted data, synchronization, backup, or MCP rendering.
- Use temporary directories; tests must not read or modify the user's real Agentbox library.
- Use fake values such as `dummy-secret` in fixtures.
- Keep golden MCP fixtures for Claude, Codex, and OpenCode aligned with renderer behavior.
- Test failure and rollback paths, not only successful writes.
- Before a release, require all tests to pass, a successful release build, `git diff --check`, DMG verification, and a secret scan.

## UI and error handling

- Keep destructive actions behind a confirmation dialog.
- Do not dismiss an editor or preview before an asynchronous save has reported success.
- Errors must remain available in operation history even when a temporary toast disappears.
- Show the exact target paths and planned additions, updates, and removals before synchronization.
- Preserve Polish as the current product-interface and user-documentation language.

## Documentation and releases

- Update `README.md` and `docs/USER_GUIDE.md` when user-visible behavior changes.
- Add user-visible changes to the `Unreleased` section of `CHANGELOG.md`.
- For a release, move changelog entries under the new version and date, update both version fields in `Resources/Info.plist`, and ensure the DMG filename matches the version.
- Use Markdown release notes from a file or real newline characters; never publish literal `\n` sequences.
- Keep `appcast.xml` aligned with the newest GitHub Release, sign every update archive with the Sparkle EdDSA key stored in Keychain, and never export or commit the private key.
- Do not commit, tag, push, create a GitHub Release, or upload artifacts unless the user explicitly requests it.

## Code review rules

- Flag any path that can expose a secret through Git, logs, snapshots, previews without warning, or test fixtures.
- Flag persistence changes that cannot decode existing MVP data.
- Flag synchronization paths that can leave partial writes or update a manifest after a failed file operation.
- Flag deletion based only on a computed path rather than an Agentbox-owned manifest.
- Flag release changes where `Info.plist`, `CHANGELOG.md`, the Git tag, and DMG filename disagree.
