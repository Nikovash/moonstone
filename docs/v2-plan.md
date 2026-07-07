# Moonstone v2 Plan

## Overview

Moonstone v2 is planned as a major modernization of the Moonstone smartnode toolkit. This document serves as both a public milestone and a reminder of what I was thinking about at a specific time.

Version 1.0 established the working script suite:

* `moonstone.sh`
* `update_ip.sh`
* `update_conf.sh`
* `safe_view.sh`
* `rock_grind.sh`
* `uninstall.sh`

Version 2 will move Moonstone from a loose set of helper scripts into a unified smartnode management app with a cleaner command interface, shared internal logic, and an optional terminal UI.

The main goal is to make Moonstone easier to use, easier to maintain, and safer for long-term smartnode management.

---

## Primary Goals

* Replace the script-first layout with a unified `moonstone` entrypoint
* Drop `.sh` from the main user-facing command
* Add command-line flags for direct use and automation
* Add an interactive terminal UI when running `./moonstone` with no arguments
* Fold current helper scripts into Moonstone commands
* Preserve existing v1 install behavior where possible
* Improve state tracking for active, inactive, and uninstalled nodes
* Add a read-only diagnostic mode called `--doctor`
* Add integrated Bitoreum binary upgrade support
* Separate Moonstone self-management into a helper app called `moonrise`

---

## Target Command Interface

```bash
./moonstone

./moonstone -h
./moonstone --help

./moonstone -i
./moonstone --install

./moonstone --update-ip <user>
./moonstone --update-conf <user>

./moonstone --view-conf <user>
./moonstone --safe-view-conf <user>

./moonstone -rg
./moonstone --rock-grind

./moonstone --uninstall <user>

./moonstone --users

./moonstone --doctor <user>

./moonstone -up
./moonstone --upgrade
```

### Command Meanings

| Command                   | Purpose                                                |
| ------------------------- | ------------------------------------------------------ |
| `./moonstone`             | Opens the interactive terminal UI                      |
| `-h`, `--help`            | Shows command help                                     |
| `-i`, `--install`         | Runs the smartnode installer                           |
| `--update-ip <user>`      | Updates `bind` and `externalip` for a smartnode user   |
| `--update-conf <user>`    | Updates stored smartnode reference fields              |
| `--view-conf <user>`      | Shows full `bitoreum.conf` after warning               |
| `--safe-view-conf <user>` | Shows `bitoreum.conf` with BLS private key redacted    |
| `-rg`, `--rock-grind`     | Suggests the best Bitoreum binary for the current host |
| `--uninstall <user>`      | Destructively uninstalls a smartnode user              |
| `--users`                 | Shows known Moonstone-managed users and status         |
| `--doctor <user>`         | Runs a read-only smartnode health check                |
| `-up`, `--upgrade`        | Checks for and installs newer Bitoreum binaries        |

---

## Interactive Terminal UI

Running Moonstone with no arguments should open an interactive terminal UI.

Preferred UI backend:

```bash
whiptail
```

Possible fallback:

```bash
dialog
```

The interactive menu should expose the same core actions as the CLI.

Example menu:

```text
Moonstone - Crystal Bitoreum Smartnode Manager

1) Install new smartnode
2) View installed users
3) Run doctor / health check
4) Update IP
5) Update config placeholders
6) Safe-view config
7) Full-view config
8) Rock grind binary suggestion
9) Upgrade Bitoreum binaries
10) Uninstall smartnode
0) Exit
```

The TUI should call the same internal functions as the CLI commands. The TUI must not contain separate duplicate logic.

---

## Moonrise Helper App

Moonstone should not be responsible for replacing or uninstalling itself.

A separate helper app named `moonrise` should manage Moonstone itself.

```bash
moonrise --check
moonrise --upgrade
moonrise --repair
moonrise --uninstall
moonrise --version
```

### Separation of Responsibilities

```text
moonstone = manages Bitoreum smartnodes
moonrise  = manages Moonstone itself
```

### Upgrade Meaning

```bash
moonstone --upgrade
```

Upgrades Bitoreum node binaries:

* `bitoreumd`
* `bitoreum-cli`

```bash
moonrise --upgrade
```

Upgrades Moonstone itself.

This separation avoids confusion and avoids self-replacing script problems.

---

## Target Project Layout

Proposed source tree:

```text
moonstone/
  moonstone
  moonrise
  VERSION
  README.md
  LICENSE

  docs/
    release-notes.md
    v2-plan.md

  lib/
    common.bash
    logging.bash
    users.bash
    conf.bash
    service.bash
    release.bash
    firewall.bash
    ui.bash

  commands/
    install.bash
    update-ip.bash
    update-conf.bash
    view-conf.bash
    safe-view-conf.bash
    rock-grind.bash
    uninstall.bash
    users.bash
    doctor.bash
    upgrade.bash
```

The user-facing command should be extensionless:

```bash
./moonstone
```

Internal modules may use `.bash`.

---

## Target Installed Layout

Long-term installed layout:

```text
/opt/moonstone/app/
  moonstone
  moonrise
  VERSION
  lib/
  commands/

/opt/moonstone/users
/opt/moonstone/backups/
/opt/moonstone/nodes.tsv

/usr/local/bin/moonstone -> /opt/moonstone/app/moonstone
/usr/local/bin/moonrise  -> /opt/moonstone/app/moonrise
```

The `/opt/moonstone/users` file should be preserved for v1 compatibility.

Future richer state should live in:

```text
/opt/moonstone/nodes.tsv
```

or:

```text
/opt/moonstone/nodes.json
```

The initial v2 implementation may use TSV for simplicity.

---

## State Tracking

Version 1 tracks currently installed users in:

```bash
/opt/moonstone/users
```

Version 2 should preserve current users and add historical state tracking.

Suggested fields:

```text
username	status	created_at	updated_at	service	conf_path	backup_path
```

Example:

```text
bob	active	2026-07-07T12:00:00Z	2026-07-07T12:00:00Z	kojack.service	/home/kojack/.bitoreumcore/bitoreum.conf	
jane	inactive	2026-07-07T12:00:00Z	2026-07-07T12:30:00Z	cisco.service	/home/cisco/.bitoreumcore/bitoreum.conf	
test01	uninstalled	2026-07-07T12:00:00Z	2026-07-07T13:00:00Z	test01.service		/opt/moonstone/backups/test01-bitoreum.conf
```

### User Status Definitions

| Status        | Meaning                                                              |
| ------------- | -------------------------------------------------------------------- |
| `active`      | User exists, config exists, and service is active or available       |
| `inactive`    | User or config exists, but service is not currently active           |
| `uninstalled` | Moonstone previously managed the user, but the smartnode was removed |
| `unknown`     | Moonstone has a record but cannot confidently determine state        |

---

## Doctor Command

`--doctor <user>` should be a read-only diagnostic command.

It should not change files, restart services, open firewall ports, or edit configs.

Purpose:

```text
Tell the user what appears wrong with a Moonstone-managed smartnode.
```

Example:

```bash
./moonstone --doctor kojack
```

Example output:

```text
Moonstone Doctor: kojack

[OK]   System user exists
[OK]   Datadir exists
[OK]   bitoreum.conf exists
[OK]   smartnodeblsprivkey present
[OK]   rpcport found: 8901
[OK]   systemd unit exists: kojack.service
[OK]   service active
[OK]   bitoreumd binary exists
[OK]   bitoreum-cli binary exists
[OK]   P2P port listening: 15168
[WARN] externalip differs from detected public IP
[OK]   disk free: 28G
[OK]   recent debug.log shows accepted blocks
```

### Doctor Checks

#### User and Install Checks

* System user exists.
* User appears in Moonstone state.
* Home directory exists.
* Bitoreum datadir exists.
* `bitoreum.conf` exists.
* Config ownership appears correct.

#### Config Checks

* `smartnodeblsprivkey` is present.
* `rpcport` is present.
* `bind` is present.
* `externalip` is present.
* `externalip` includes port `15168`.
* `onlynet=ipv4` is present.
* `daemon=1` is present.
* `listen=1` is present.
* `txindex=1` is present.

#### Service Checks

* `<user>.service` exists.
* Service is enabled.
* Service is active.
* Recent systemd failures are reported.
* Unit file points to the expected datadir and config.

#### Binary Checks

* `bitoreumd` exists.
* `bitoreum-cli` exists.
* Installed binary versions can be read.
* Installed versions can be compared against the latest release.

#### Network Checks

* P2P port `15168` is listening.
* RPC port is listening locally.
* `bind` IP exists on the machine.
* Detected public IP matches or differs from `externalip`.
* UFW or iptables appears to allow `15168`.

#### Runtime Checks

* `bitoreum-cli` can talk to the daemon.
* Current block height can be read.
* Peer count can be read.
* Sync status can be estimated.
* Recent `debug.log` errors are summarized.
* Recent accepted blocks are detected.

#### System Checks

* Disk free space.
* RAM and swap.
* OS information.
* Architecture.
* Oracle / OCI detection summary.
* Raspberry Pi / Ampere hardware hints.

---

## Upgrade Command

`--upgrade` should manage Bitoreum binaries, not Moonstone itself.

```bash
./moonstone --upgrade
./moonstone -up
```

Expected behavior:

* Detect installed `bitoreumd` version.
* Detect installed `bitoreum-cli` version.
* Query latest Bitoreum release.
* Compare local version to latest release.
* Select the best binary tarball for the current host.
* Ask before replacing binaries.
* Stop Moonstone-managed smartnode services before upgrade.
* Back up current binaries before replacement.
* Install new binaries into `/usr/bin` or the configured binary path.
* Restart services that were previously running.
* Report success or failure.

The existing `rock_grind` logic should become the selection engine for this command.

---

## Rock Grind Command

`--rock-grind` should remain a non-destructive binary suggestion tool.

```bash
./moonstone --rock-grind
./moonstone -rg
```

Purpose:

* Detect host architecture.
* Detect Oracle / Ampere hints.
* Detect Raspberry Pi hints.
* Query latest Bitoreum release assets.
* Suggest the best matching Linux binary.
* Print alternate suggestions.

This command should not install or replace anything.

---

## Config Viewing

Version 2 should separate full config viewing from safe config viewing.

### Safe View

```bash
./moonstone --safe-view-conf <user>
```

* Read-only.
* Redacts `smartnodeblsprivkey`.
* Suitable for screenshots, streams, Discord support, and troubleshooting.

### Full View

```bash
./moonstone --view-conf <user>
```

* Read-only.
* Shows the full config.
* Warns before displaying sensitive values.
* Requires explicit confirmation before printing.

Example warning:

```text
WARNING: This may display smartnodeblsprivkey.
Do not stream, screenshot, or share this output.

Type SHOW to continue:
```

---

## Uninstall Safety

Smartnode uninstall remains destructive:

```bash
./moonstone --uninstall <user>
```

This command may:

* Stop services.
* Disable services.
* Remove systemd units.
* Back up config.
* Terminate user processes.
* Delete the Linux user.
* Delete the user home directory.
* Mark the node as uninstalled in Moonstone state.

Because of this, uninstall should have no short flag.

It should require explicit confirmation.

Recommended confirmation:

```text
Type the username to continue:
```

---

## Versioning

Version 1 introduced a root-level `VERSION` file.

Version 2 should continue using `VERSION` as the canonical Moonstone version source unless a better metadata format becomes necessary.

Required commands:

```bash
./moonstone --version
./moonrise --version
```

Suggested output:

```text
Moonstone 2.0.0
```

For `moonrise`:

```text
Moonrise 2.0.0
Managing Moonstone 2.0.0
```

---

## Logging

Version 2 should keep timestamped logs.

Installer logs may continue under:

```bash
./logs/
```

Installed app logs may use:

```bash
/opt/moonstone/logs/
```

Logging requirements:

* Never log passwords.
* Never log `smartnodeblsprivkey`.
* Never log full unredacted config unless explicitly requested and clearly warned.
* Log command start and end.
* Log detected environment.
* Log service changes.
* Log binary upgrade actions.
* Log uninstall actions.

---

## Backwards Compatibility

Version 2 should avoid breaking existing v1 installs.

Compatibility goals:

* Read existing `/opt/moonstone/users`.
* Detect existing `<username>.service` units.
* Detect existing `/home/<user>/.bitoreumcore/bitoreum.conf`.
* Preserve existing backup location:

```bash
/opt/moonstone/backups/
```

* Optionally provide wrapper scripts for one transition release:

```bash
moonstone.sh       -> ./moonstone --install
update_ip.sh      -> ./moonstone --update-ip "$@"
update_conf.sh    -> ./moonstone --update-conf "$@"
safe_view.sh      -> ./moonstone --safe-view-conf "$@"
rock_grind.sh     -> ./moonstone --rock-grind "$@"
uninstall.sh      -> ./moonstone --uninstall "$@"
```

---

## Migration Plan

On first v2 run, Moonstone should check for v1 state.

If `/opt/moonstone/users` exists:

1. Read each username.
2. Check whether the Linux user exists.
3. Check whether the datadir exists.
4. Check whether the config exists.
5. Check whether the service exists.
6. Determine active/inactive/unknown state.
7. Write or update the v2 state file.
8. Preserve the original `/opt/moonstone/users`.

Migration should not delete anything.

Migration should be safe to run more than once.

---

## Non-Goals for Initial v2

The first v2 implementation does not need to solve everything.

Initial v2 does not need:

* A graphical desktop app.
* Remote fleet management.
* Automatic unattended self-update.
* Multi-coin support.
* Non-Linux support.
* Windows support.
* macOS support.
* Full package manager integration.
* Automatic repair actions from `--doctor`.

Doctor should be read-only first.

Repair actions can be added later once checks are reliable.

---

## Implementation Phases

### Phase 1 - Structure

* Add extensionless `moonstone` entrypoint
* Add `--help`
* Add `--version`
* Add command parser
* Add shared library directory
* Add command directory
* Add compatibility wrappers if needed

### Phase 2 - Existing Helper Integration

* Move install flow behind `--install`
* Move IP update behind `--update-ip`
* Move config update behind `--update-conf`
* Move safe view behind `--safe-view-conf`
* Move rock grind behind `--rock-grind`
* Move uninstall behind `--uninstall`

### Phase 3 - Interactive TUI

* Add `whiptail/dialog`-based main menu
* Add user picker
* Add confirmation dialogs
* Add TUI views for status and doctor output
* Keep CLI paths fully functional

### Phase 4 - State Tracking

* Add richer node state file
* Add `--users`
* Migrate v1 `/opt/moonstone/users`
* Track active/inactive/uninstalled state
* Preserve legacy state compatibility

### Phase 5 - Doctor

* Add read-only health checks
* Add service checks
* Add config checks
* Add network checks
* Add runtime checks
* Add log summary checks

### Phase 6 - Bitoreum Binary Upgrade

* Promote rock grind matching logic into reusable release-selection code
* Add installed-vs-latest comparison
* Add binary backup
* Add safe service stop/restart
* Add `--upgrade` / `-up`

### Phase 7 - Moonrise

* Add `moonrise` helper
* Add Moonstone update check
* Add repair command
* Add self-upgrade flow
* Add Moonstone uninstall flow

---

## Acceptance Criteria for v2

Moonstone v2 should be considered successful when:

* `./moonstone` opens an interactive TUI
* `./moonstone --help` clearly documents all commands
* `./moonstone --install` can perform the existing install flow
* Existing helper functionality works through the new command interface
* Existing v1 users can still be detected
* `--users` reports active/inactive/uninstalled state
* `--doctor <user>` provides useful read-only diagnostics
* `--safe-view-conf <user>` redacts the BLS private key
* `--view-conf <user>` requires a warning confirmation
* `--rock-grind` remains non-destructive
* `--upgrade` upgrades Bitoreum binaries, not Moonstone itself
* `moonrise` is reserved for Moonstone self-management
* Destructive actions require explicit confirmation
* Sensitive secrets are not written to logs
