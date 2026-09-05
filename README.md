# labWithDevopsTools

This repository contains labSetup.sh — a small, opinionated installer script that sets up an ultra-minimal Remote DevOps Workstation on Ubuntu 22.04.

## What the script does

labSetup.sh performs a non-interactive installation of a curated set of developer and DevOps tools and (optionally) a lightweight desktop environment for remote RDP access. It is intended for use in lab or VM environments.

Installed components (summary):

- Docker (and Docker CLI)
- Node.js (LTS)
- AWS CLI
- kubectl
- Helm
- Terraform (via HashiCorp apt repo)
- Minikube
- k9s
- Ansible
- Common utilities: git, curl, wget, jq, vim, htop, build-essential, python3, python3-pip, python3-venv, unzip
- Optional (with `--with-desktop`): XFCE, xrdp, xorgxrdp, firefox-esr

The script also creates a workspace at /opt/workspace and a small status/info report under /opt.

## Requirements

- Tested on: Ubuntu 22.04
- Must be run as root (use `sudo`)
- Internet access required to download packages and binaries
- Recommended minimal resources when using Minikube: 2 CPUs, ~2–4GB RAM (adjust when starting minikube)

## Usage

Make the script executable and run it as root:

```bash
sudo chmod +x labSetup.sh
sudo ./labSetup.sh            # Server-only installation
sudo ./labSetup.sh --with-desktop   # Install XFCE, XRDP, Firefox (RDP access)
```

The script logs its output to `/var/log/devbox-install.log` and writes summary/status files to `/opt/DEVBOX-INFO.txt` and `/opt/DEVBOX-STATUS.txt`.

## What to expect after installation

- Reboot the machine (recommended): `sudo reboot`
- If you installed the desktop, RDP will be available on port 3389. If not, SSH is available on port 22.
- Start Minikube (example):

```bash
minikube start --driver=docker --memory=2200 --cpus=2 --disk-size=6000mb
```

- Check summary and status:

```bash
sudo cat /opt/DEVBOX-INFO.txt
sudo cat /opt/DEVBOX-STATUS.txt
sudo tail -n 200 /var/log/devbox-install.log
```

## Security & permissions notes

- The script adds the real user (the invoking sudo user) to the `docker` group so they can run Docker without sudo. This grants the same level of access as root for container-related operations — be careful with untrusted users.
- When XFCE + XRDP is enabled, the script adds `xrdp` to `ssl-cert` group and creates a minimal XRDP start script at `/etc/xrdp/startwm.sh`.
- UFW rules are configured to allow SSH (22) and, if installed, RDP (3389). The script does not enable the firewall automatically; it only creates the allow rules.

## Troubleshooting

- If a package install fails, inspect `/var/log/devbox-install.log` for details.
- If Docker doesn't start, run `sudo systemctl status docker` and `sudo journalctl -u docker --no-pager` to view logs.
- If XRDP is used and the session doesn't start, check `/var/log/xrdp-sesman.log` and `/var/log/xrdp.log`.

## Customization

- The script uses non-interactive apt installs and minimal recommended packages. Modify the package lists in the script to add/remove tools.
- Terraform is installed via HashiCorp's apt repository; change or pin versions in the script as needed.

## License

This repository contains a convenience installer script and README. Use at your own risk. No warranty provided.

---

Created from: `labSetup.sh`

-- To connect to this lab 
git remote add localhost ssh://git@localhost:7722/root/juice-shop
