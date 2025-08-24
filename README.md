
<p align="center">
  <img src="assets/script_logo.png" alt="Moonstone Logo" width="200"/>
</p>

<h1 align="center">Moonstone</h1>
<h3 align="center">The Crystal Bitoreum Smartnode Setup Script</h3>

This project provides the main **bash script** (`moonstone.sh`) for installing and configuring a Bitoreum smartnode on Debian/Ubuntu Linux systems.  
It also includes tools to **update** non-critical config values (`update_conf.sh`), tools to **update** the ip(s) (`update_ip.sh`), and to **uninstall** a node cleanly (`uninstall.sh`).

---

## Features

- Ensures the script runs on **Linux only** (exits on macOS/Windows).
- **Prompts** you to confirm the Bitoreum daemon is stopped before continuing.
- Installs required packages: `dialog`, `nano`, `fail2ban`, `unzip`, `curl`, `jq`, `ca-certificates`, `lsb-release`, `openssl`, `iproute2` (and `ufw` when needed).
- Verifies minimum **RAM/Swap**:
  - 2 GB RAM minimum, **or**
  - 1 GB RAM + 2 GB swap.
  - Auto-creates swap if insufficient (skips swap entirely when physical RAM ≥ 4 GB).
- Detects any existing **bitoreumd** / **bitoreum-cli** and logs versions.
- Fetches the **latest Bitoreum release** assets from GitHub (e.g., `powcache.dat`) and supports an optional **bootstrap** download from the official host.
- **Oracle Cloud** handling:
  - Auto-detects OCI where possible.
  - Configures `iptables` (via `iptables-persistent`) to allow ports **22** and **15168**.
- **Non-Oracle** systems:
  - Ensures **UFW** is installed/enabled.
  - Opens ports **22** and **15168** and reloads rules.
- Recovers from failed installs by cleaning prior users/configs when requested.
- Creates a dedicated **non-root** user to run the smartnode.
- Writes `.bitoreumcore/bitoreum.conf` with user-provided keys and collateral data.
- Creates/enables a **systemd service** that keeps the node alive (unit name = chosen username).
- Records installed usernames in `/opt/moonstone/users`.
- Provides:
  - **`update_conf.sh`** to safely update non-critical, commented config placeholders.
  - **`uninstall.sh`** to back up config, stop/disable service, and remove the user cleanly.
- Logs actions to **`./logs/setup-<timestamp>.log`**.

---

## Requirements

- A Linux VPS (Ubuntu/Debian recommended).
- Sufficient **RAM/Swap** per the rules above.
- Ability to run commands as **root** (via `sudo` or root shell).

---

## Moonstone.sh Usage

Clone the repository:

```bash
git clone https://github.com/Nikovash/moonstone
cd moonstone
```

Make the main script executable (optional; it may already be executable):

```bash
chmod +x moonstone.sh
```

Run the script:

```bash
./moonstone.sh
```

Once installed, you can manage the smartnode service (the unit name is the **username** you chose):

**START**
```bash
sudo systemctl start <username>
```

**STOP**
```bash
sudo systemctl stop <username>
```

### update_conf.sh | Update Non-Critical Data
Use `update_conf.sh` to update optional (commented out) fields in the user’s `bitoreum.conf`:

```bash
./update_conf.sh
```
**or**
```bash
./update_conf.sh <username>
```

- Script will safely stop the daemon, allow for edits and tehn restart the daemon
- Without arguments, it will iterate through the known installed users
- With a username, it targets that user directly
- The script stops the service, prompts for values (blank = **keep**; `#` = **comment/clear**), and then restarts the service if it was running

### update_ip.sh | Update Critical Data
Use `update_ip.sh` to update the **bind** and **external** IPs in the user's `bitoreum.conf`:

```bash
./update_ip.sh
```
**or**
```bash
./update_ip.sh <username>
```

- Script will safely stop the daemon, allow for edits and tehn restart the daemon
- Without arguments, it will iterate through the known installed users
- With a username, it targets that user directly
- The script stops the service, prompts for values (blank = **keep**), and then restarts the service if it was running

### Uninstalling
We ship an **uninstaller** that requires an explicit username (this is destructive):

```bash
./uninstall.sh <username>
```

- The username must exist in `/opt/moonstone/users`
- The user’s `bitoreum.conf` is backed up to:
  ```
  /opt/moonstone/backups/<username>-bitoreum.conf
  ```
  so you can recover data such as voting address or BLS keys later
  
### safe_view.sh | Stream-Friendly bitoreum.conf Viewer
Security is paramount when dealing with the `smartnodeblskey` field, but we still wish to be friendly to users making their own contnet 
without feed of exposing this senstive data, as such we created this little utility that allows you to should the contents of a users `bitoreum.conf` 
file while obsucring the `smartnodeblskey`:

```bash
./safe_view.sh
```
**or**
```bash
./safe_view.sh <username>
```
- Without arguments, it will iterate through the known installed users
- With a username, it targets that user directly
- This script edits nothign and is just used for display purposes only

---

### Firewall Notes

- **Oracle VPS**: The script configures persistent `iptables` to allow ports **22** and **15168**.
- **Non-Oracle VPS**: The script ensures **UFW** is installed/enabled and opens **22** and **15168**.

---

### Logging

All activity is logged to timestamped files in:

```bash
./logs/
```

Example:
```
./logs/setup-20250101-120000.log
```

After a successful install, the username is also recorded in:

```bash
/opt/moonstone/users
```

This makes future maintenance (e.g., uninstall) easier

---

### Determine Best Binary

For those of you who do not wish to do things manually we even have a tool for you `rock_grind.sh` checks your current system and determines the best binary for you based on facts about your system and checks them against the current release.
```bash
./rock_grind.sh
```
OR
```bash
./rock_grind.sh -n 5
```
Should give you the top three best guesses

---

## Disclaimer

These scripts are provided **as-is**, and without warranty. Use at your own risk!  
Always back up your data and keys before running installation scripts.
