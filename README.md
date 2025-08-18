<p align="center">
  <img src="assets/script_logo.png" alt="Moonstone Logo" width="200"/>
</p>

# Moonstone
## The Crystal Bitoreum Smartnode Setup Script

This project provides a **single bash script** (`moonstone.sh`) for
installing and configuring a Bitoreum smartnode on (Debian/Ubuntu) Linux systems.

---

### Features

-   Ensures the script only runs on **Linux** (exits if run on macOS or
    Windows)
-   ask user if **Bitoreum daemon is stopped** before continuing
-   Installs required packages: `dialog`, `nano`, `fail2ban`, `unzip`, `curl`, `jq`, `ca-certificates`, `lsb-release`, `openssl`, `iproute2`
    and conditionally `ufw`
-   Verifies minimum **RAM and swap requirements**:
    - 2GB RAM minimum, or
    - 1GB RAM + 2GB swap
    - Auto-creates swap if insufficient, based on thresholds
    - Ignore creating SWAP if physical RAM is more than 4GB
-   Detects global installations of **bitoreumd** and **bitoreum-cli**,
    ensures version consistency
-   Downloads the **latest Bitoreum release** from GitHub, including
    optional `powcache.dat` and `bootstrap.zip` if available
-   Handles **Oracle Cloud VPS** instances specially:
    - Modifies `/etc/iptables/rules.v4` to allow ports `22` and
        `15168`
-   For non-Oracle systems:
    - Ensures **ufw** is installed
    - Opens ports `22` and `15168`
    - Reloads firewall rules
-   Allows recovery from failed smartnode installations by cleaning up
    old users/configs
-   Creates a dedicated non-sudo **smartnode user**
-   Sets up the required `.bitoreumcore/bitoreum.conf` with
    user-provided keys and collateral details
-   Creates and enables a **systemd service** to keep the node alive
-   Logs successes, info, and failures to `moonstone.log`
-	Update non-critcal conf data `update_conf.sh`
-	Uninstall `uninstall.sh` script included


---

### Requirements

-   A fresh **Linux VPS** (Ubuntu/Debian recommended)
-   Sufficient **RAM/Swap** per the rules above
-   Ability to run commands as **root** (`sudo` or root shell)

---

### Usage

Clone the repository:

``` bash
git clone https://github.com/YOUR_USERNAME/moonstone
cd moonstone
```

Make the script executable: (optional script is shipped executable)

``` bash
chmod +x moonstone.sh
```

Run the script **as root**:

``` bash
./moonstone.sh
```
Once this script has sucessfully installed you can start and stop the `bitoreum` daemon with:
**START**
```bash
sudo systemctl start <username>
```
**STOP**
```bash
sudo systemctl start <username>
```

To add data to a conf file, after successful install we have provided an `update_conf.sh` script that can be used:
```bash
./update_conf.sh
```
OR
```bash
./update_conf.sh <username>
```
The first version will cycle through all known installed users, the second one invokes a specific user. This will stop the deamon, ask you questions about the data you want to update empty values are considered `skip`. Once all data has been entered this script attempts to restart the daemon
<p><p>
We now ship an unistaller script that requires an explicit username to execute because of the destructive nature of this action:
```bash
./uninstall.sh <username>
```
The <username> must match one in the installed list. the `bitoreum.conf` file for that user is stored in /opt/moonstone/backups<username>-bitoreum.conf to be recoverable in the future if you wish to reuse the data such as voting address, `bls` keys, etc.
 
 
---

### Firewall Notes

-   **Oracle VPS**: The script directly edits `iptables` rules to allow
    required ports
-   **Non-Oracle VPS**: The script ensures `ufw` is installed, enables
    it if not, reloads it, and ensures ports `22` and `15168` are open

---

### Logging

The script logs all activity to:

``` bash
moonstone.log
```

This file records successes, failures, and informational messages

If sucessful this script logs the user installed on in:
```bash
cat /opt/moonstone/users
```

This will make cleanup (uninstall) easier in the future

---
## Disclaimer

This script is provided **as-is**, and without warranty. Use at your own risk! Always back up
your data and keys before running installation scripts.
