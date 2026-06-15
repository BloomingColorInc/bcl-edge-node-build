# Blooming Color Edge Node Build Guide

## NetBird Routing + Monitoring + Remote Administration Platform

Version: 1.1
Target Hardware: HP EliteDesk 800 G4 SFF (or equivalent)
Target OS: Ubuntu Server 24.04 LTS
Purpose: Site Edge Infrastructure (VPN, Monitoring, Remote Administration)

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

Boot the edge node from the USB drive and install:

Ubuntu Server 24.04.x LTS

Installation choices:

Network:

* Configure Static IP

Storage:

* Use the installer defaults
* Accept the default partitioning layout for the target drive
* In most cases the target drive is the built-in 1TB SSD

Packages:

* OpenSSH Server

Hostname examples:

bcl-edge-lom-01
bcl-edge-lou-01

Create administrator:

netadmin

Reboot.

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

The bootstrap script automates the repeatable host configuration work:

* OS package refresh and base utility installation
* Docker installation and enablement
* NetBird package installation
* XFCE, XRDP, and session configuration
* Portainer Agent deployment
* Netdata installation
* LibreNMS working directory creation
* Baseline UFW rules for SSH and XRDP

Run:

```bash
sudo EDGE_ADMIN_USER=netadmin bash scripts/bootstrap-edge-node.sh
```

Optional environment flags:

```bash
sudo EDGE_ADMIN_USER=netadmin \
INSTALL_DESKTOP=yes \
INSTALL_NETDATA=yes \
INSTALL_PORTAINER=yes \
CONFIGURE_UFW=yes \
bash scripts/bootstrap-edge-node.sh
```

Defaults:

* `EDGE_ADMIN_USER=netadmin`
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

The bootstrap script installs the NetBird package, but site enrollment remains manual.

Join:

```bash
sudo netbird up
```

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

Test:

Windows:

mstsc

Connect:

NetBird-IP

---

# 10. Portainer Agent

The bootstrap script deploys the Portainer Agent container by default.

Verify:

```bash
docker ps --filter name=portainer-agent
```

---

# 11. Netdata

The bootstrap script installs Netdata by default.

Verify:

http://SERVER:19999

---

# 12. Install LibreNMS Poller

Prepared by script:

```bash
ls -ld /opt/librenms
```

Deploy poller container.

Register with AWS Triad.

---

# 13. Firewall

The bootstrap script enables UFW and allows:

* SSH
* TCP 3389 for XRDP

Restrict management to NetBird.

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

Add node as Secondary.

Validate.

Promote:

Metric 10

Retain legacy peers:

Metric 100

Verify failover.

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
