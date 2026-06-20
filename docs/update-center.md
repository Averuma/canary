# Canary Update Center

The update center manages the local Canary Docker stack, Canary source status,
and the OTClient installation without replacing user data or silently
overwriting customized client files.

## Commands

Run these commands from PowerShell:

```powershell
.\tools\update-center.cmd
.\tools\update-center.cmd -Action Backup
.\tools\update-center.cmd -Action UpdateSource
.\tools\update-center.cmd -Action UpdateServer
.\tools\update-center.cmd -Action UpdateClient
.\tools\update-center.cmd -Action UpdateAll
.\tools\update-center.cmd -Action RollbackClient
```

Running the command without arguments opens an interactive terminal menu.
Direct `-Action` commands remain available for VS Code tasks and automation.
Mutating actions ask for confirmation. Use `-Yes` only for scheduled
unattended execution.
The `.cmd` launcher applies `ExecutionPolicy Bypass` only to that invocation,
without changing the user's permanent PowerShell policy.

## Server behavior

Before recreating backend containers, the script backs up MariaDB and OTClient
user data. It pulls the configured Docker images, recreates the backend
services, reapplies Lua configuration overrides, deploys configured data-file
overlays, and restarts the Canary service.

Source updates are separate from runtime-image updates. `UpdateSource`
fast-forwards a clean local `main` or merges `upstream/main` into a clean
`dudantas/*` working branch. It refuses dirty worktrees and unrelated branch
names. It never resets, rebases, commits unrelated changes, or pushes. The
personal fork is `origin`; the official OpenTibiaBR repository is `upstream`.

## GitHub workflow

The interactive menu can show both repositories, publish both working
branches, and synchronize them with their official sources:

- Canary merges `upstream/main` into the current `dudantas/*` branch;
- OTClient merges the latest official release tag into its current
  `dudantas/*` branch;
- publishing always uses the explicit current branch name on `origin`;
- the updater never pushes to `origin/main` or to the official `upstream`;
- operations stop when either worktree contains uncommitted changes.

## Client behavior

The client updater uses official GitHub releases. It compares the installed
files with the previous official release:

- unchanged official files receive the new version;
- locally modified files are preserved and reported as conflicts;
- `%AppData%\Roaming\otcr\otclient\otclient` is never replaced;
- every overwritten or removed file receives a rollback copy.

Close `otclient.exe` before running `UpdateClient`.

## Scheduling

For a safe scheduled check, run only:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "\\wsl.localhost\Ubuntu\home\vgr19\canary\tools\update-center.ps1" -Action Status
```

Automatic installation should be enabled only after reviewing the status
output and testing one manual update cycle.

## Visual Studio Code

Open `Canary-OTClient.code-workspace` to load the Canary repository and
`C:\OTClient` in the same Explorer. Use `Terminal > Run Task` to access:

- update status, backup, backend/client updates, and client rollback;
- Docker stack start, stop, status, and Canary restart;
- live Canary and OTClient logs;
- OTClient launch and user-data folder access.

Update tasks remain interactive and ask for confirmation before changing the
runtime.
