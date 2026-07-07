# Version 1.0 - initial release

### Core Installer

* Added the initial `moonstone.sh` installer.
* Supports Debian/Ubuntu-style Linux environments.
* Requires root or sudo access.
* Refuses to run on unsupported non-Linux systems.
* Prompts the user to confirm the Bitoreum daemon has been stopped before continuing.
* Creates timestamped setup logs under:

```bash
./logs/
```

* Installs required host packages, including:

```bash
dialog
nano
fail2ban
unzip
curl
jq
ca-certificates
lsb-release
openssl
iproute2
htop
```

### System Resource Checks

* Detects installed RAM and swap.
* Enforces minimum memory requirements for smartnode operation.
* Skips swap creation when physical RAM is at least 4 GB.
* Creates and enables a swapfile when available RAM/swap is below the expected threshold.
* Sets lower swap aggressiveness with `vm.swappiness=10`.

### Host and Hardware Detection

* Detects host CPU architecture using `uname -m`.
* Maps common architectures to Moonstone/Bitoreum asset labels:

  * `x86_64`
  * `i686`
  * `aarch64`
  * `armhf`
* Attempts to detect Raspberry Pi hardware.
* Attempts to detect Raspberry Pi 4 or newer.
* Attempts to detect Ampere / Neoverse N1 hardware.
* Attempts to detect Oracle Cloud / OCI environments using available system metadata, DMI data, Oracle Cloud Agent presence, and OCI metadata checks.

### Binary Detection and Installation

* Checks for existing installed Bitoreum binaries:

```bash
/usr/bin/bitoreumd
/usr/bin/bitoreum-cli
```

* Logs detected binary versions when available.
* Queries the latest Bitoreum GitHub release.
* Reads available release assets.
* Selects the best matching Linux binary tarball for the detected host environment.
* Prefers more specific release assets when available, including:

  * Oracle / Ampere ARM64 builds
  * Raspberry Pi 4+ ARM64 builds
  * Generic Linux ARM64 builds
  * Generic Linux ARM32 builds
  * Generic Linux x86_64 builds
  * Generic Linux x86_32 builds
* Downloads the selected binary tarball.
* Extracts the archive.
* Installs `bitoreumd` and `bitoreum-cli` into:

```bash
/usr/bin/
```

* Skips binary download when the installed binaries already appear to match the latest release tag.

### Chain Data Helpers

* Queries the latest Bitoreum release for `powcache.dat`.
* Downloads `powcache.dat` into the selected user’s Bitoreum data directory when available.
* Allows the user to provide a custom `powcache.dat` URL if the release asset is missing.
* Offers an optional bootstrap download from:

```bash
https://bitoreum.cc/bootstrap/bootstrap.zip
```

* Extracts bootstrap data into the selected user’s Bitoreum data directory when accepted.
* Allows the user to skip bootstrap if they prefer a normal sync.

### Firewall and Security Setup

* Configures Fail2Ban for SSH protection.
* Enables and starts the Fail2Ban service.
* Handles firewall setup differently depending on detected host environment.

#### Oracle Cloud / OCI

* Installs `iptables-persistent` when needed.
* Adds persistent firewall rules for:

  * SSH port `22`
  * Bitoreum P2P port `15168`
* Saves rules using `netfilter-persistent` when available.

#### Non-Oracle Hosts

* Installs UFW when needed.
* Allows:

  * `22/tcp`
  * `15168/tcp`
* Enables or reloads UFW.

### Smartnode User Setup

* Prompts for the smartnode runtime username.
* Refuses to use `root` as the runtime user.
* Creates a dedicated non-root Linux user when the selected user does not already exist.
* Prompts for and confirms a password for the new runtime user.
* Supports reusing an existing user when appropriate.
* Creates the Bitoreum data directory:

```bash
/home/<user>/.bitoreumcore
```

### Failed Install Recovery

* Detects existing `bitoreum.conf` files under `/home` and `/root`.
* Provides a recovery path for failed prior installs.
* Can remove previous smartnode users and services when the user confirms cleanup.
* Can reuse a previous username after cleaning prior smartnode data.
* Scans systemd unit directories for services referencing `bitoreumd`.

### Smartnode Configuration

* Creates a new `bitoreum.conf` for the selected runtime user.
* Collects smartnode registration and identity values, including:

  * `CollateralHash`
  * `smartnodePublicKey`
  * `smartnodeblsprivkey`
  * `OwnerAddress`
  * `VotingAddress`
* Reuses existing RPC port and BLS values when an existing config is found.
* Automatically selects an unused RPC port starting from:

```bash
8901
```

* Detects the private IPv4 address.
* Detects the external IPv4 address.
* Adds port `15168` to the external IP when no port is supplied.
* Writes IPv4-only networking settings:

```bash
onlynet=ipv4
bind=<private-ip>
externalip=<external-ip>:15168
```

* Sets core node options:

```bash
daemon=1
listen=1
txindex=1
```

* Sets local RPC options:

```bash
rpcbind=127.0.0.1
rpcallowip=127.0.0.1
rpcport=<selected-port>
```

### Systemd Service

* Creates a systemd service for the selected user.
* Uses the username as the service name:

```bash
<username>.service
```

* Runs `bitoreumd` as the dedicated non-root user.
* Starts the daemon with the selected datadir and config file.
* Stops the daemon using `bitoreum-cli stop`.
* Enables the service at boot.
* Restarts the service on failure.
* Applies basic systemd hardening options:

  * `PrivateTmp=true`
  * `ProtectSystem=full`
  * `NoNewPrivileges=true`
  * `PrivateDevices=true`
  * `MemoryDenyWriteExecute=true`
* Truncates `debug.log` before service start.
* Starts the service after install.
* Tails the user’s `debug.log` after startup.

### Moonstone User Tracking

* Creates the Moonstone state directory:

```bash
/opt/moonstone
```

* Records installed runtime usernames in:

```bash
/opt/moonstone/users
```

* Uses the recorded users list for helper scripts and later maintenance tasks.

### Configuration Update Helper

* Added `update_conf.sh`.
* Allows updating stored smartnode reference fields in a user’s `bitoreum.conf`.
* Reads known Moonstone users from:

```bash
/opt/moonstone/users
```

* Can target a user directly by argument.
* Prompts the user to select from known users when no username is provided.
* Stops the user’s systemd service before editing when the service is active.
* Creates a timestamped backup of the config before editing.
* Stores selected smartnode reference values as commented placeholders.
* Supports updating or clearing:

  * `CollateralHash`
  * `ProTXHash`
  * `smartnodePublicKey`
  * `OwnerAddress`
  * `VotingAddress`
* Restarts the service after editing if it was previously running.

### IP Update Helper

* Added `update_ip.sh`.
* Allows updating `bind` and `externalip` values in a user’s `bitoreum.conf`.
* Reads known Moonstone users from:

```bash
/opt/moonstone/users
```

* Can target a user directly by argument.
* Prompts the user to select from known users when no username is provided.
* Stops the user’s systemd service before editing when the service is active.
* Creates a timestamped backup of the config before editing.
* Shows the current `bind` and `externalip` values before prompting.
* Allows blank input to keep current values.
* Automatically appends `:15168` to `externalip` when a port is not supplied.
* Restarts the service after editing if it was previously running.

### Safe Config Viewer

* Added `safe_view.sh`.
* Provides a read-only way to display a user’s `bitoreum.conf`.
* Redacts the `smartnodeblsprivkey` value before printing.
* Preserves the rest of the config for troubleshooting, screenshots, streams, or support requests.
* Reads known Moonstone users from:

```bash
/opt/moonstone/users
```

* Can target a user directly by argument.
* Prompts the user to select from known users when no username is provided.
* Makes no changes to the config file.

### Binary Suggestion Helper

* Added `rock_grind.sh`.
* Detects host architecture.
* Detects Raspberry Pi hardware hints.
* Detects Raspberry Pi 4+ hardware hints.
* Detects Ampere / Oracle-style ARM hosts.
* Queries the latest Bitoreum GitHub release.
* Reads available release assets.
* Suggests the best matching Linux tarball for the current host.
* Prints the top recommendation and additional alternates.
* Supports changing the number of suggestions with:

```bash
./rock_grind.sh -n 5
```

### Uninstaller

* Added `uninstall.sh`.
* Requires an explicit username.
* Refuses to uninstall `root`.
* Requires the username to exist in:

```bash
/opt/moonstone/users
```

* Warns that uninstall is destructive.
* Requires confirmation before proceeding.
* Stops, disables, and removes related systemd services.
* Scans systemd unit directories for additional services referencing the target user or datadir.
* Backs up the user’s `bitoreum.conf` to:

```bash
/opt/moonstone/backups/<username>-bitoreum.conf
```

* Terminates remaining processes for the target user.
* Removes lingering runtime directories when possible.
* Deletes the Linux user and home directory.
* Removes the username from:

```bash
/opt/moonstone/users
```

### Known Limitations

* The main installer is still a linear Bash installer rather than a unified Moonstone command app.
* Helper tools are separate `.sh` scripts instead of subcommands under one `moonstone` entrypoint.
* The installer is currently oriented around Debian/Ubuntu-style systems and uses `apt-get`.
* There is no interactive `dialog` / TUI menu yet.
* There is no `--doctor` health-check command yet.
* There is no integrated `--upgrade` command yet.
* User tracking only records currently installed users in `/opt/moonstone/users`; it does not yet preserve historical active/inactive/uninstalled node state.
* `safe_view.sh` redacts the BLS private key, but full and safe config viewing are not yet separated into formal Moonstone commands.
* `rock_grind.sh` suggests binaries but does not install or upgrade them.
* Bootstrap download uses a hardcoded bootstrap URL.
* The current release remains script-first and maintenance-helper based.
