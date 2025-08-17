<p align="center">
  <img src="assets/script_logo.png" alt="Moonstone Logo" width="200"/>
</p>

# Moonstone
## The Crystal Bitoreum Smartnode Setup Script

This project provides a **single bash script** (`moonstone.sh`) for
installing and configuring a Bitoreum smartnode on Linux systems.

------------------------------------------------------------------------

### Features

-   Ensures the script only runs on **Linux** (exits if run on macOS or
    Windows)
-   Confirms the **Bitoreum daemon is stopped** before continuing
-   Installs required packages: `dialog`, `nano`, `fail2ban`, `unzip`,
    and conditionally `ufw`
-   Verifies minimum **RAM and swap requirements**:
    -   2GB RAM minimum, or
    -   1GB RAM + 2GB swap
    -   Auto-creates swap if insufficient, based on thresholds
-   Detects global installations of **bitoreumd** and **bitoreum-cli**,
    ensures version consistency
-   Downloads the **latest Bitoreum release** from GitHub, including
    optional `powcache.dat` and `bootstrap.zip` if available
-   Handles **Oracle Cloud VPS** instances specially:
    -   Modifies `/etc/iptables/rules.v4` to allow ports `22` and
        `15168`
-   For non-Oracle systems:
    -   Ensures **ufw** is installed
    -   Opens ports `22` and `15168`
    -   Reloads firewall rules
-   Allows recovery from failed smartnode installations by cleaning up
    old users/configs
-   Creates a dedicated non-sudo **smartnode user**
-   Sets up the required `.bitoreumcore/bitoreum.conf` with
    user-provided keys and collateral details
-   Creates and enables a **systemd service** to keep the node alive
-   Logs successes, info, and failures to `moonstone.log`

------------------------------------------------------------------------

### Requirements

-   A fresh **Linux VPS** (Ubuntu/Debian recommended)
-   Sufficient **RAM/Swap** per the rules above
-   Ability to run commands as **root** (`sudo` or root shell)

------------------------------------------------------------------------

### Usage

Clone the repository:

``` bash
git clone https://github.com/YOUR_USERNAME/moonstone-smartnode.git
cd moonstone-smartnode
```

Make the script executable: (optional script is shipped executable)

``` bash
chmod +x moonstone.sh
```

Run the script **as root**:

``` bash
sudo ./moonstone.sh
```

------------------------------------------------------------------------

### Firewall Notes

-   **Oracle VPS**: The script directly edits `iptables` rules to allow
    required ports
-   **Non-Oracle VPS**: The script ensures `ufw` is installed, enables
    it if not, reloads it, and ensures ports `22` and `15168` are open

------------------------------------------------------------------------

### Logging

The script logs all activity to:

``` bash
moonstone.log
```

This file records successes, failures, and informational messages.

------------------------------------------------------------------------

## Disclaimer

This script is provided **as-is**, and without warranty. Use at your own risk! Always back up
your data and keys before running installation scripts.
