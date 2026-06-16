# BloomingEdge Node Build Guide

> **READ FIRST:** Read through the entire document before attempting any of the steps so you understand the full workflow, prerequisites, and manual follow-up items. This guide assumes you will use SSH for remote management after the initial OS installation.

## Zero-Trust VPN Routing + Remote Access + System Monitoring Platform

![BloomingEdge Network](img/BloomingEdge_Network.png)

Version: 0.1 (beta)
Target Hardware: HP EliteDesk 800 G4 SFF (or equivalent)
Target OS: Ubuntu Server 24.04 LTS
Purpose: Site Edge Infrastructure (Intersite Connectivity, Remote Access, Network Device Monitoring)

---

# 1. Overview

BloomingEdge Nodes provide localized edge infrastructure for intersite connectivity, secure remote access, and network device monitoring at each site.

Primary functions:

* NetBird Routing Peer (Primary)
* Site-to-Site Overlay Networking
* Remote User Access
* LibreNMS Distributed Poller
* Portainer Agent
* Maintenance Automation
* Emergency GUI Administration

High Availability is provided by retaining existing NetBird Routing Peers as secondary routing peers.

---

# 2. Hardware Specification

Recommended:

## Base System

HP EliteDesk 800 G4 SFF

Minimum:

* Intel i7-8700
* 32GB DDR4 RAM
* 1TB NVMe SSD

## Add-on NIC

Recommended:

* Intel I350-T2
* Intel I350-T4

Temporary:

* Intel 82576 Dual Port Gigabit

---

# 3. BIOS Configuration

Update BIOS before installing Linux.

If this is a new or refurbished PC that shipped with Windows pre-installed, the easiest way to get the latest BIOS or firmware update is usually through Windows Update before you wipe the machine.

Firmware updates are recommended before installation, regardless of the system's prior operating system.

Recommended settings:

Security:

* Secure Boot → Disabled

Virtualization:

* VT-x → Enabled
* VT-d → Enabled

Power:

* Wake-on-LAN → Enabled
* Automatic Power Recovery → Enabled

Boot:

* UEFI → Enabled
* PXE → Disabled
* USB Boot → Enabled

Save and reboot.

---

# 4. Install Ubuntu Server

Create the installer USB on a Windows workstation:

1. Download the current Ubuntu Server 24.04.x ISO.
2. Insert a USB flash drive with at least 8GB capacity.
3. Open Rufus.
4. Select the USB device.
5. Select the Ubuntu Server 24.04.x ISO.
6. Accept the Rufus defaults for partition scheme and write options unless site policy requires otherwise.
7. Start the write process and wait for Rufus to complete.

Boot the edge node from the USB drive and start the Ubuntu Server 24.04.x LTS installer.

Installation choices:

Network:

* Configure initial networking (DHCP or Static IP)

Storage:

* Use the guided installer defaults
* Accept the default partitioning layout for the target drive
* In most cases the target drive is the built-in 1TB SSD
* Only change this if your site has an explicit storage requirement

Packages:

* OpenSSH Server

Hostname examples:

bcl-edge-lom-01
bcl-edge-lou-01

Create administrator:

netadmin

Reboot.

After the initial installation, SSH is available for remote management and for copying and pasting the commands in this guide from another machine.

Connect from your management workstation:

1. ***While still at the edge node computer***, run this command in the local console to find the machine IP address:

```bash
ip a
```

2. ***At your remote admin workstation***, connect over SSH using that IP address (replace `<node-ip>`):

```bash
ssh netadmin@<node-ip>
```

3. On first connection, type `yes` to trust the host key, then enter the `netadmin` password.

4. Optional: copy your SSH public key so future logins do not require a password:

```bash
ssh-copy-id netadmin@<node-ip>
```

5. Verify remote access and host identity:

```bash
hostname
whoami
```

---

# 5. Clone the Repository

If `git` is not already installed:

```bash
sudo apt update
sudo apt install -y git
```

Clone the public repository:

```bash
git clone https://github.com/bloomingcolorinc/bcl-edge-node-build.git
cd bcl-edge-node-build
```

The repository is hosted in the `bloomingcolorinc` GitHub organization.

---

# 6. Run the Bootstrap Script

Run the bootstrap script after the operating system is installed and you can reach the node over SSH. It handles the repeatable parts of the build:

* OS package refresh and base utility installation
* Docker installation and enablement
* NetBird package installation and enrollment when a setup key is provided
* NetBird routing-peer host preparation (persistent IPv4/IPv6 forwarding)
* XFCE, XRDP, and session configuration
* Portainer Agent deployment
* SNMP daemon installation for host polling
* LibreNMS working directory creation
* Baseline UFW rules for SSH and XRDP

Before running the script, generate a NetBird one-off setup key in the NetBird management dashboard:

1. Sign in to the NetBird admin console.
2. Open Peers → Servers.
3. Select Add Peer or Generate Key.
4. Copy the generated one-off key.

> **READ FIRST:** NetBird one-off setup keys are shown only once when created. Copy and securely save the key before closing the dialog, or you will need to generate a new key.

If your organization manages keys from Settings → Setup Keys instead, create a new one-off key there and copy it immediately before you close the dialog.

Run the script from the cloned repository:

Because the bootstrap command is long, you may want to copy it into your text editor of choice, replace placeholder values (such as `<setup-key>` and hostname), then paste the final command into your SSH session.

```bash
sudo EDGE_ADMIN_USER=netadmin \
NETBIRD_SETUP_KEY=<setup-key> \
NETBIRD_HOSTNAME=bcl-edge-lom-01 \
bash scripts/bootstrap-edge-node.sh
```

`NETBIRD_SETUP_KEY` should contain that one-off key copied from the NetBird dashboard. Pass it in as an environment variable when you start the script; do not store it in the repository.

Each bootstrap run now logs full output to:

* `edge-node-bootstrap.log` (latest run)
* `edge-node-bootstrap-YYYYmmdd-HHMMSS.log` (timestamped run record)

Both files are written to your current working directory by default.

To write logs somewhere else, set `BOOTSTRAP_LOG_DIR`. To force a single explicit log path, set `BOOTSTRAP_LOG_FILE`.

Directory example:

```bash
sudo BOOTSTRAP_LOG_DIR=/var/log \
EDGE_ADMIN_USER=netadmin \
NETBIRD_SETUP_KEY=<setup-key> \
NETBIRD_HOSTNAME=bcl-edge-lom-01 \
bash scripts/bootstrap-edge-node.sh
```

Single-file example:

```bash
sudo BOOTSTRAP_LOG_FILE=/var/log/edge-node-bootstrap.log \
EDGE_ADMIN_USER=netadmin \
NETBIRD_SETUP_KEY=<setup-key> \
NETBIRD_HOSTNAME=bcl-edge-lom-01 \
bash scripts/bootstrap-edge-node.sh
```

The bootstrap script is designed to be re-runnable (idempotent) for normal operations. In repair situations, you can force re-application of key components with repair flags.

Optional environment flags:

`INSTALL_BLOOMINGEDGE_WALLPAPER` defaults to `yes`.
NetBird routing-peer preparation is always enabled in both standard and repair modes.

```bash
sudo EDGE_ADMIN_USER=netadmin \
NETBIRD_SETUP_KEY=<setup-key> \
NETBIRD_HOSTNAME=bcl-edge-lom-01 \
INSTALL_DESKTOP=yes \
INSTALL_BLOOMINGEDGE_WALLPAPER=yes \
INSTALL_PORTAINER=yes \
CONFIGURE_UFW=yes \
REPAIR_MODE=no \
FORCE_NETBIRD_REENROLL=no \
FORCE_PORTAINER_REDEPLOY=no \
bash scripts/bootstrap-edge-node.sh
```

Repair-mode example (forces NetBird re-enrollment and Portainer redeploy):

```bash
sudo EDGE_ADMIN_USER=netadmin \
NETBIRD_SETUP_KEY=<setup-key> \
NETBIRD_HOSTNAME=bcl-edge-lom-01 \
REPAIR_MODE=yes \
bash scripts/bootstrap-edge-node.sh
```

Defaults:

* `EDGE_ADMIN_USER=netadmin`
* `NETBIRD_SETUP_KEY=<setup-key>` for unattended NetBird enrollment
* `NETBIRD_HOSTNAME=bcl-edge-lom-01` or `bcl-edge-lou-01`
* `INSTALL_DESKTOP=yes`
* `INSTALL_PORTAINER=yes`
* `CONFIGURE_UFW=yes`
* `ENABLE_FULL_UPGRADE=yes` (runs `apt-get upgrade` only within the current Ubuntu release; it does not perform `do-release-upgrade`)
* `REPAIR_MODE=no` (set to `yes` for emergency repair re-application)
* `FORCE_NETBIRD_REENROLL=no` (set to `yes` to force `netbird down` then `netbird up`)
* `FORCE_PORTAINER_REDEPLOY=no` (set to `yes` to recreate the Portainer agent container)

---

# 7. Configure Networking

Identify interfaces:

```bash
ip a
```

Create Netplan:

```bash
sudo nano /etc/netplan/00-edge.yaml
```

Example:

```yaml
network:
 version: 2
 renderer: networkd

 ethernets:
   eno1:
     dhcp4: false
     addresses:
       - 192.9.200.50/24

     routes:
       - to: default
         via: 192.9.200.1

     nameservers:
       addresses:
         - 192.9.200.10
         - 1.1.1.1
```

Apply:

```bash
sudo netplan apply
```

---

# 8. Join NetBird

When the bootstrap script runs with `NETBIRD_SETUP_KEY`, the node enrolls as a NetBird peer during that same run. You do not need to run the bootstrap script again.

After the peer appears in the dashboard, create the network route or exit node that points at it and assign the appropriate distribution group or auto-apply setting. Use a network route for site-to-site access to private subnets, or an exit node if you want the peer to carry internet-bound traffic for connected clients. That dashboard step is what makes the peer act as the routing endpoint for your site network.

Verify:

```bash
netbird status
```

Configure as:

Primary Metric:
10

Existing peers:
100

---

# 9. GUI and XRDP

The bootstrap script installs XFCE, LightDM, XRDP, Google Chrome, sets the BloomingEdge wallpaper, configures the admin user's XFCE session, updates `/etc/xrdp/startwm.sh`, and enables the relevant services.

For existing nodes where desktop behavior needs to be corrected (for example local console input issues or wallpaper not applying), rerun bootstrap in repair mode:

```bash
sudo EDGE_ADMIN_USER=netadmin \
REPAIR_MODE=yes \
INSTALL_DESKTOP=yes \
INSTALL_BLOOMINGEDGE_WALLPAPER=yes \
bash scripts/bootstrap-edge-node.sh
```

If you skip desktop installation by setting `INSTALL_DESKTOP=no`, complete the GUI and XRDP setup manually before remote access testing.

The only reason to use the desktop is emergency or out-of-band administration. Normal day-to-day management should happen over SSH and NetBird.

Test:

Windows:

mstsc

Connect:

NetBird-IP

---

# 10. Portainer Agent

The bootstrap script deploys the Portainer Agent container by default so the node can be managed from Portainer without a separate install step.

Verify:

```bash
docker ps --filter name=portainer-agent
```

---

# 11. SNMP Agent, Portainer, and LibreNMS Stack

The bootstrap script installs and starts the host SNMP daemon (`snmpd`). LibreNMS and other monitoring systems use that service to poll the node.

After the node is reachable over NetBird, edit the SNMP configuration and restrict access to your NetBird subnet.

```bash
sudo nano /etc/snmp/snmpd.conf
```

Set a read-only community string and permit only your management subnet. A simple starting point looks like this:

```conf
agentAddress udp:161
rocommunity <snmp-community> <netbird-subnet>
sysLocation Edge node
sysContact netadmin
```

Then restart the service and make sure it starts on boot:

```bash
sudo systemctl restart snmpd
sudo systemctl enable snmpd
```

If UFW is enabled, allow SNMP from the same subnet only:

```bash
sudo ufw allow from <netbird-subnet> to any port 161 proto udp
```

The repository includes a Docker Compose stack for:

* LibreNMS (`librenms`)
* LibreNMS dispatcher (`dispatcher`)
* MariaDB (`db`)
* Redis (`redis`)
* Portainer Agent (`portainer-agent`)

Set strong database credentials before launching the stack:

```bash
export DB_PASSWORD='<strong-db-password>'
```

Then start the stack from the repository root:

```bash
sudo -E docker compose up -d
```

Verify:

```bash
docker compose ps
docker ps --filter name=portainer-agent
systemctl status snmpd
```

Use LibreNMS to add this node as a polled device after SNMP is reachable over NetBird.

How this communicates with AWS Triad:

1. NetBird creates the encrypted overlay between this edge node and the AWS Triad environment.
2. Portainer Agent listens on port 9001 on this node, and the Portainer server in AWS Triad connects to it over the NetBird network for remote container operations.
3. The local LibreNMS services (`librenms`, `dispatcher`, `db`, `redis`) run on this node and monitor local devices through SNMP.
4. In distributed monitoring deployments, polling data and coordination traffic are exchanged with AWS Triad services over NetBird instead of exposing services directly to the public internet.
5. Operational access (SSH, Portainer, monitoring traffic) should be restricted to NetBird-managed addresses and groups.

AWS Triad configuration steps:

1. In NetBird, place AWS management services (Portainer server, AWS LibreNMS, automation hosts) in a management group, and place BloomingEdge nodes in an edge group.
2. Create NetBird access policies that allow management-to-edge traffic only for required ports:
  * TCP 22 for SSH
  * TCP 9001 for Portainer Agent
  * UDP 161 for SNMP polling
  * Any additional monitoring ports used by your standards
3. Do not publish these management services to public internet paths; use NetBird overlay addressing as the primary path.

Portainer in AWS to BloomingEdge:

1. In AWS Portainer, create or select the target environment group for edge sites.
2. Add each BloomingEdge node as an Agent environment using its NetBird IP or DNS name on port `9001`.
3. Tag environments by site, role, and lifecycle state (for example `lom`, `edge`, `primary`).
4. Validate connectivity from Portainer by confirming endpoint status is healthy and container inventory is visible.
5. Use RBAC in Portainer so only approved operator roles can deploy or restart edge workloads.

LibreNMS in AWS to BloomingEdge:

1. In AWS LibreNMS, add each BloomingEdge node as a device using its NetBird IP address and SNMP credentials.
2. Assign each node to site groups so alert routing and maintenance windows can be managed per location.
3. If you are using distributed pollers, map the correct poller group to each site and ensure NetBird policies allow poller-to-device SNMP paths.
4. Add service checks for internal stack endpoints you want AWS to track (for example Portainer Agent reachability or application health URLs on the edge host).
5. Validate by running discovery and polling, then confirm graphs and alerts populate for both the host and selected internal services.

---

# 12. Firewall

The bootstrap script enables UFW and allows:

* SSH
* TCP 3389 for XRDP

Restrict management to NetBird.

If your site uses additional management services, add only the ports you actually need.

---

# 13. Validation

Verify:

```bash
docker ps
netbird status
systemctl status xrdp
systemctl status chrony
```

Test:

* Remote Desktop
* NetBird Routing
* SNMP Polling
* Portainer

## Operations CLI Menu

The repository includes an interactive operations menu script for day-2 node administration:

```bash
sudo bash scripts/edge-node-ops.sh
```

The menu provides high-level operations for:

* Docker stack lifecycle (`up`, `down`, `restart`, `pull`, status, and logs)
* NetBird peer operations (`status`, `up` with setup key, `down`, and service restart)
* Quick node health checks for core services and containers

---

# 14. Production Cutover

Add the node as a secondary routing peer first.

Validate that traffic flows correctly.

Promote the node by assigning it metric 10.

Keep legacy peers at metric 100 so they remain secondary.

Verify failover before you cut over production traffic.

---

# Final Architecture

AWS Triad
↓
BloomingEdge Overlay
↓
LOM Edge (Primary)
↓
LOU Edge (Primary)

Backups:

* Raspberry Pi
* Hyper-V VM

Edge Services:

* NetBird
* LibreNMS
* Portainer
* Automation
* XRDP
* XFCE
* SSH
* Docker
