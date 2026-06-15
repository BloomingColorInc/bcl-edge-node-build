# Blooming Color Edge Node Build Guide

## NetBird Routing + Monitoring + Remote Administration Platform

Version: 1.2
Target Hardware: HP EliteDesk 800 G4 SFF (or equivalent)
Target OS: Ubuntu Server 24.04 LTS
Purpose: Site Edge Infrastructure (VPN, Monitoring, Remote Administration)

Read through the entire document before attempting any of the steps so you understand the full workflow, prerequisites, and manual follow-up items. This guide assumes you will use SSH for remote management after the initial installation.

---

# 1. Overview

BloomLink Edge Nodes provide localized network infrastructure services at each site.

Primary functions:

* NetBird Routing Peer (Primary)
* Site-to-Site Overlay Networking
* Remote User Access
* LibreNMS Distributed Poller
* Netdata Monitoring
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

* Configure Static IP

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

---

# 5. Clone the Repository

If `git` is not already installed:

```bash
sudo apt update
sudo apt install -y git
```

Clone the public repository:

```bash
git clone https://github.com/bloomingcolorinc/bcl-edge-computer-config.git
cd bcl-edge-computer-config
```

The repository is hosted in the `bloomingcolorinc` GitHub organization.

---

# 6. Run the Bootstrap Script

Run the bootstrap script after the operating system is installed and you can reach the node over SSH. It handles the repeatable parts of the build:

* OS package refresh and base utility installation
* Docker installation and enablement
* NetBird package installation and enrollment when a setup key is provided
* XFCE, XRDP, and session configuration
* Portainer Agent deployment
* Netdata installation
* LibreNMS working directory creation
* Baseline UFW rules for SSH and XRDP

Run the script from the cloned repository:

```bash
sudo EDGE_ADMIN_USER=netadmin \
NETBIRD_SETUP_KEY=<setup-key> \
NETBIRD_HOSTNAME=bcl-edge-lom-01 \
bash scripts/bootstrap-edge-node.sh
```

Optional environment flags:

```bash
sudo EDGE_ADMIN_USER=netadmin \
NETBIRD_SETUP_KEY=<setup-key> \
NETBIRD_HOSTNAME=bcl-edge-lom-01 \
INSTALL_DESKTOP=yes \
INSTALL_NETDATA=yes \
INSTALL_PORTAINER=yes \
CONFIGURE_UFW=yes \
bash scripts/bootstrap-edge-node.sh
```

Defaults:

* `EDGE_ADMIN_USER=netadmin`
* `NETBIRD_SETUP_KEY=<setup-key>` for unattended NetBird enrollment
* `NETBIRD_HOSTNAME=bcl-edge-lom-01` or `bcl-edge-lou-01`
* `INSTALL_DESKTOP=yes`
* `INSTALL_NETDATA=yes`
* `INSTALL_PORTAINER=yes`
* `CONFIGURE_UFW=yes`
* `ENABLE_FULL_UPGRADE=yes`

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

The bootstrap script can enroll the node automatically when you provide a NetBird setup key. That step registers the machine as a NetBird peer, but it does not yet make it the routing endpoint for your site.

For a bare metal server or routing peer, create the key from the NetBird management dashboard:

1. Sign in to the NetBird admin console.
2. Open Peers → Servers.
3. Select Add Peer or Generate Key.
4. Copy the generated one-off key.

Run the bootstrap script with that key so the machine enrolls as a NetBird peer:

```bash
sudo EDGE_ADMIN_USER=netadmin \
NETBIRD_SETUP_KEY=<setup-key> \
NETBIRD_HOSTNAME=bcl-edge-lom-01 \
bash scripts/bootstrap-edge-node.sh
```

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

The bootstrap script installs XFCE, LightDM, XRDP, configures the admin user's XFCE session, updates `/etc/xrdp/startwm.sh`, and enables the relevant services.

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

# 11. Netdata

The bootstrap script installs Netdata by default so you can confirm system health immediately after the build.

Verify:

http://SERVER:19999

---

# 12. Install LibreNMS Poller

Prepared by script:

```bash
ls -ld /opt/librenms
```

Deploy the LibreNMS poller container after the node is enrolled and reachable over NetBird.

Register it with AWS Triad using the polling credentials and site details from your monitoring standard.

---

# 13. Firewall

The bootstrap script enables UFW and allows:

* SSH
* TCP 3389 for XRDP

Restrict management to NetBird.

If your site uses additional management services, add only the ports you actually need.

---

# 14. Validation

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
* Netdata

---

# 15. Production Cutover

Add the node as a secondary routing peer first.

Validate that traffic flows correctly.

Promote the node by assigning it metric 10.

Keep legacy peers at metric 100 so they remain secondary.

Verify failover before you cut over production traffic.

---

# Final Architecture

AWS Triad
↓
BloomLink Overlay
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
* Netdata
* Portainer
* Automation
* XRDP
* XFCE
* SSH
* Docker
