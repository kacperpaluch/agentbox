# AGENTS.md

## Project overview

Agentbox is a native macOS 14+ application and CLI written in Swift 6. It manages a shared library of AI skills and MCP server configurations for Claude Code, Codex, and OpenCode.

The application prepares files and directories for those clients. It does not run MCP servers, perform OAuth, or replace the clients themselves.

## Repository map

- `Sources/SkillboxCore/` — models, persistence, imports, rendering, synchronization, Git backup, and external process execution.
- `Sources/SkillboxApp/` — SwiftUI/AppKit macOS interface.
- `Sources/SkillboxCLI/` — command-line interface.
- `Tests/SkillboxCoreTests/` — integration-style core tests and golden fixtures.
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
- Preserve actor isolation for `SkillboxStore` and `SkillboxService`.
- Keep the core Foundation-based where practical. AppKit-specific code belongs in `SkillboxApp`.
- Prefer small, explicit models over untyped dictionaries except at JSON/TOML serialization boundaries.
- Keep CLI and GUI behavior consistent when they expose the same operation.

## Data compatibility

- Existing MVP libraries must remain readable. The default data directory intentionally retains the legacy name `~/Library/Application Support/Skillbox`.
- Treat changes to `Catalog`, `LocalConfiguration`, `MCPConfiguration`, and persisted nested models as schema changes.
- When adding persisted fields, provide backward-compatible decoding through defaults, optionals, or an explicit migration.
- Do not silently discard malformed or unknown user data.
- Preserve atomic writes and create recovery snapshots before mutating library metadata.
- Never add `projects.local.json`, `mcp-secrets.json`, or `.agentbox-snapshots/` to the library Git backup.

## Secrets and MCP safety

- `mcp-secrets.json` is local and intentionally excluded from Git, but it is not encrypted yet. Do not describe it as encrypted or Keychain-backed.
- Never log, commit, snapshot, or include actual API keys and MCP tokens in fixtures, errors, documentation, or release notes.
- Keep user-controlled classification for imported MCP values: environment reference, local secret, or literal value.
- Treat automatic secret detection as a suggestion, not an authoritative decision.
- Preserve manual MCP entries in project files. A naming conflict with an unmanaged entry must stop synchronization instead of overwriting it.
- Generated project configurations may contain resolved secrets. Maintain `.git/info/exclude` protection and visible warnings, while remembering that already tracked files are not protected by exclude rules.

## Synchronization invariants

- Preview must be computed before modifying a project.
- `Synchronizuj wszystko` must remain transactional across skills and MCP files.
- Back up every managed target before replacement and roll back all earlier changes if a later write fails.
- Update manifests only after their corresponding writes succeed.
- Do not ignore file-removal or replacement errors.
- Never delete directories that are not listed in an Agentbox manifest.
- Keep project-level sync backups bounded; the current retention limit is 10.
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
