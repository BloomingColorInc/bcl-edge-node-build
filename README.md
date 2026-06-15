# Blooming Color Edge Node Build Guide

## NetBird Routing + Monitoring + Remote Administration Platform

Version: 1.0
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

Install:

Ubuntu Server 24.04 LTS

Installation choices:

Network:

* Configure Static IP

Storage:

* Manual

Suggested partitions:

/boot      2GB
swap       16GB
/          150GB
/var       300GB
/opt       Remaining

Packages:

* OpenSSH Server

Hostname examples:

bcl-edge-lom-01
bcl-edge-lou-01

Create administrator:

netadmin

Reboot.

---

# 5. Initial OS Configuration

Update:

```bash
sudo apt update
sudo apt full-upgrade -y
sudo reboot
```

Install utilities:

```bash
sudo apt install \
curl \
wget \
git \
htop \
nano \
vim \
net-tools \
chrony \
lm-sensors \
jq \
unzip \
zip \
ufw
```

Enable time sync:

```bash
sudo systemctl enable chrony
```

---

# 6. Configure Networking

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

# 7. Install Docker

Install:

```bash
curl -fsSL https://get.docker.com | sudo sh
```

Add user:

```bash
sudo usermod -aG docker netadmin
```

Enable:

```bash
sudo systemctl enable docker
```

Verify:

```bash
docker ps
```

---

# 8. Install NetBird

Install:

```bash
curl -fsSL https://pkgs.netbird.io/install.sh | sudo bash
```

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

# 9. Install Lightweight GUI

Install XFCE:

```bash
sudo apt install \
xfce4 \
xfce4-goodies \
lightdm \
xorg \
dbus-x11 \
xubuntu-default-settings
```

Select:

lightdm

Configure:

```bash
echo startxfce4 > ~/.xsession
chmod +x ~/.xsession
```

Restart:

```bash
sudo systemctl restart display-manager
```

---

# 10. Configure XRDP

Install:

```bash
sudo apt install \
xrdp \
xorgxrdp
```

Configure session:

```bash
echo xfce4-session > ~/.xsession
```

Edit:

```bash
sudo nano /etc/xrdp/startwm.sh
```

Replace final lines with:

```bash
export DESKTOP_SESSION=xfce
export XDG_CURRENT_DESKTOP=XFCE
exec startxfce4
```

Add permissions:

```bash
sudo adduser xrdp ssl-cert
```

Restart:

```bash
sudo systemctl restart xrdp
```

Test:

Windows:

mstsc

Connect:

NetBird-IP

---

# 11. Install Portainer Agent

Deploy:

```bash
docker run -d \
--restart=always \
-p 9001:9001 \
-v /var/run/docker.sock:/var/run/docker.sock \
-v /var/lib/docker/volumes:/var/lib/docker/volumes \
portainer/agent
```

---

# 12. Install Netdata

Install:

```bash
bash <(curl -Ss https://my-netdata.io/kickstart.sh)
```

Verify:

http://SERVER:19999

---

# 13. Install LibreNMS Poller

Create:

```bash
mkdir -p /opt/librenms
```

Deploy poller container.

Register with AWS Triad.

---

# 14. Firewall

Allow:

```bash
sudo ufw allow ssh
sudo ufw allow 3389/tcp
sudo ufw enable
```

Restrict management to NetBird.

---

# 15. Validation

Verify:

```bash
docker ps
netbird status
systemctl status xrdp
```

Test:

* Remote Desktop
* NetBird Routing
* SNMP Polling
* Portainer
* Netdata

---

# 16. Production Cutover

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
