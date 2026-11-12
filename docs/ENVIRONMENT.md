# Helper 0.7.0 environment preparation

Windows Helper now reuses the environment preparation from `gbc-expert-manager`.
It checks for Node >= 20, deploys the existing bundled Node 22.22.2 (including
npm and npx), and configures the same registry-scoped read-only npm access as
the installer. It does not download anything or create MCP entries on its own.

## MCP dependency sync (GMSCP-7877)

After a WorkBuddy-target expert installation succeeds, the Helper merges each
installed expert package's declared MCP dependencies (`<plugin>/.mcp.json` or
`plugin.json` → `dependencies.mcpServers`) into the user-level
`~/.workbuddy/mcp.json`. This is what makes an expert-team update actually move
the MCP version instead of freezing it at the first resolution (previously the
user had to delete the MCP and re-enter the PAT).

The merge is intentionally conservative:

- Only existing entries are refreshed. Entries are never created here — first
  install belongs to WorkBuddy's connect card (tokenSchema), which collects the
  GBC PAT; writing `${PLACEHOLDER}` values would shadow that flow.
- `type`/`command`/`args`/`runtime` come from the package declaration (the
  package pins an exact MCP version — see gbc-agent-plugins docs/06A §6).
- Env keys declared as `${PLACEHOLDER}` keep the user's configured value
  (GBC_TOKEN, GBC_BASE_URL); literal values (GBC_PROFILE) come from the package.
  A placeholder without a configured value is omitted, never written literally.
- Everything else on the existing entry (headers, custom keys) is preserved,
  including a manually added `--registry <url>` argument pair.
- The file is rewritten without a BOM (WorkBuddy fails strict JSON parsing on
  BOM), unparseable files are left untouched for manual inspection, and logs
  record key names only — never token values.
- The sync runs after the installer exits successfully and never flips the
  install to failed; failures are logged loudly instead.

The managed runtime remains at
`%USERPROFILE%/.workbuddy/expert-manager/runtimes/node/22.22.2` and the npm config
at `%USERPROFILE%/.workbuddy/expert-manager/npm-workbuddy.rc`, so an existing
installer deployment can be reused. The user PATH and NPM_CONFIG_USERCONFIG
are configured for later WorkBuddy marketplace updates. Existing npm settings
and unexpanded PATH entries are preserved. Restart WorkBuddy after preparation.

Preparation runs after Setup copies its files, during the ZIP's install.cmd
flow, and before protocol-driven WorkBuddy expert installation. Failure is
logged and prevents the following expert-install step. The existing pi adapter
and GBC expert-package installation logic are unchanged.

New files shipped with both Setup and ZIP:

- helper-env.ps1
- node-runtime-win-x64.zip (copied from the current installer's assets)

The updater copies these new files. When updating from an older Helper whose
updater copies only the old files, the first preparation recovers them from
the verified update staging directory.

## Self-update without temp scripts (GMSCP-7878)

A field report (GMSCP-7878): Huorong's file realtime monitor classified
`%TEMP%\expertdock-update-<ver>\expertdock-update.cmd` as
`HEUR:TrojanDownloader/PS.NetLoader.am` and deleted it, so 检查更新 always
failed on protected machines. The detection is behavioral, not signature
based: a script host dropping a batch file into %TEMP%, cmd executing it, and
the script deleting itself is the full heuristic pattern for downloaders.
Code signing and window handling are irrelevant here — the flagged artifact is
a runtime-generated batch file that cannot be signed, and the update chain was
already `-WindowStyle Hidden`.

The switcher existed because a running instance cannot overwrite its own
files. Windows does allow renaming a running exe and a fully parsed ps1
(handles carry FILE_SHARE_DELETE), so the external script is unnecessary:

- `Swap-InstalledFile` copies the staged file next to the target as `.new`,
  renames the current file to `.old`, then promotes `.new` — milliseconds,
  no wait-for-exit window, rollback bytes preserved. Any failure throws into
  the existing 更新失败 path; there is never a half-swapped state reported as
  success.
- Non-running assets (icon, install.cmd, helper-env.ps1, runtime archive) are
  copied in place as before.
- The restart is a direct `Start-Process powershell -File` using the same
  command shape as the protocol handler and the Run key. The single-instance
  mutex is released before the new process starts (the tail release is now
  guarded against double release); the old process exits within milliseconds
  while the new one needs seconds to reach its mutex check, so there is no
  race.
- `Remove-UpdateLeftovers` sweeps `.old`/`.new` remnants at startup; locked
  files are skipped silently and retried next start.

The update staging directory under %TEMP% is retained (files are only copied
from it, never executed), and the GMSCP-7877 asset-recovery path still reads
from it. No cmd process is spawned anywhere in the update flow anymore.

## 0.7.2 release (7878 fix + 7877 re-release)

0.7.2 carries two changes: the self-update fix above and the GMSCP-7877
re-release (version bump so already-deployed 0.7.0 machines see it, startup
time MCP sync, and scanning across all marketplaces instead of my-experts
only). The MCP sync section above describes the merge semantics, which are
unchanged.

## Validation and build

Run `powershell -NoProfile -ExecutionPolicy Bypass -File tests/environment.tests.ps1`.
The tests run the bundled Node/npm/npx in a temporary directory and mock the
persistent registry, environment notification, network and process boundaries.
They do not change the machine's real user PATH, npm configuration, or
installed Helper, and they never launch cmd. The self-update suite covers the
swap primitives (running-image targets, hard-lock failures), leftover
sweeping, and the full Invoke-SelfUpdate happy path with a mocked
latest.json/download/restart, asserting zero switcher scripts and a direct
powershell restart.

Dev-shell caveat: if PSModulePath carries PowerShell 7 entries (e.g. when
`powershell` is launched from a pwsh parent), Windows PowerShell 5.1 command
discovery is shadowed and even `Get-FileHash` becomes unavailable. Run the
tests with PSModulePath reset to the 5.1 defaults; end-user processes started
from Explorer/Run-key are unaffected.

Run `powershell -ExecutionPolicy Bypass -File build-release.ps1 -Version 0.7.2`
with Inno Setup installed to build Setup, ZIP and latest.json. Use `-ZipOnly`
when only a local ZIP is needed; this deliberately does not generate publication
metadata or claim that a Setup EXE was built. Add `-Publish` to upload the
Windows ZIP, Setup EXE and latest.json to the R2 bucket with `--remote`
(wrangler 4.x defaults to a local emulator without it) and then re-download
everything from the public Worker URLs to verify hashes against latest.json.
The macOS ZIP is not built here; publish verification fails with instructions
if it is missing under `helpers/v<version>/`. Windows PowerShell scripts are
saved with a UTF-8 BOM for Windows PowerShell 5.1 compatibility.

The 0.5.0/0.6.0 release directories are unchanged; publishing 0.7.2 replaces
`helpers/latest.json` on R2, after which installed helpers receive 0.7.2 via
检查更新. Shared runtimes and npm configuration are retained on Helper
uninstall, as they may be used by WorkBuddy and the original installer.
