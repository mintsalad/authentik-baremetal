Authentik Bare-Metal Installation on Debian LXC

This repository contains a fully automated installation script for Authentik (Identity Provider / SSO solution) 
on Debian-based systems, designed to run in bare-metal or Proxmox LXC containers.


Overview:


The script automates the installation of Authentik from source, including:

Python 3.13 installation

Node.js 24 via NVM

Go 1.23 installation

Cloning the Authentik repository

Setting up a Python virtual environment with Poetry

Building the Authentik frontend (website and web)

Compiling the Authentik server binary

Creating systemd service units for server and worker processes

Basic configuration and environment setup


It is intended for Debian 12+ environments inside Proxmox LXC containers, but may work on other Debian-based distributions with minor adjustments and maybe other Linux based distributions.

The following packages are required for the script to function properly:

build-essential git curl wget unzip pkg-config libssl-dev libffi-dev \
zlib1g-dev libbz2-dev libreadline-dev libsqlite3-dev liblzma-dev \
uuid-dev python3-venv python3-distutils python3-dev gcc make cmake \
openssl npm nodejs golang jq systemd libkrb5-dev libsasl2-dev \
libldap2-dev libpq-dev libmariadb-dev-compat libmariadb-dev \
default-libmysqlclient-dev libxml2-dev libxslt1-dev libjpeg-dev tk-dev \
libgdbm-dev libncurses5-dev libncursesw5-dev

The script will install missing packages automatically using apt-get.

Installation Script:

Run the installation script as a normal user (not root), the script uses sudo where required:

gh repo clone mintsalad/authentik-baremetal
chmod +x install.sh
./install.sh

The script performs the following:

1.  Ensures directories and permissions (/opt/authentik and subdirectories)
2.  Checks disk space (minimum 10 GB recommended)
3.  Installs Python 3.13 if missing
4.  Installs yq for YAML editing
5.  Installs Node.js 24 via NVM
6.  Installs Go 1.23 if missing
7.  Clones or updates the Authentik repository
8.  Sets up a Python virtual environment and installs dependencies with Poetry
9.  Builds the frontend (website and web)
10. Builds the Authentik server binary
11. Configures systemd services for Authentik server and worker
12. Initializes default configuration, certificates, templates, and blueprints

PostgreSQL Configuration:

Authentik requires PostgreSQL. To Allow connections from your network:

1. Edit postgresql.conf:
2. change the listen_address: '*'
3. Edit pg_hba.conf to allow network access
   host  all  all  10.37.10.0/24  md5  (example)
   host  all  all  10.37.11.0/24  md5 (example)

Adding users via PostgreSQL:

Authentik stores users in the authentik_core_user table inside its PostgreSQL database.
You can add users manually if needed (for example, to bootstrap an admin account).

Connect to the Authentik database:

sudo -u postgres psql -d authentik

Insert a new user (place values as needed)

INSERT INTO authentik_core_user (
    username, email, name, is_active, is_superuser, is_staff, password, date_joined
) VALUES (
    'admin',
    'admin@example.com',
    'Administrator',
    true,
    true,
    true,
    '$argon2id$v=19$m=102400,t=2,p=8$<salt>$<hash>',
    NOW()
);


Password Hash:

Authentik uses argon2id hashes. You must generate one using the Authentik CLI:

/opt/authentik/.venv/bin/python -m authentik crypto hash-password 'YourPasswordHere'

Exit PostgreSQL:

\q


Frontend Build:

The script builds both website and web directories:

cd /opt/authentik/src/website
npm install --legacy-peer-deps
npm run build

cd /opt/authentik/src/web
npm install --legacy-peer-deps
npm run build

The build output must exist at /opt/authentik/src/website/dist and /opt/authentik/src/web/dist.

Enable and start services:

sudo systemctl enable authentik-server authentik-worker
sudo systemctl start authentik-server authentik-worker

Check Status:

sudo systemctl status authentik-server
sudo systemctl status authentik-worker

UFW/Firewall Rules:

If using UFW, allow PostgreSQL and Authentik connections from your network:

sudo ufw allow from 10.37.10.0/24 to any port 5432 (postgresql)
sudo ufw allow from 10.37.11.0/24 to any port 5432 (postgresql)

sudo ufw allow from 10.37.10.0/24 to any port 9000 (authentik)
sudo ufw allow from 10.37.11.0/24 to any port 9443 (authentik)

NOTES:

- Tested on Proxmox 9.0.3 on Debian LXC containers
- Ensure /opt/authentik has enough disk space (>10GB)
- The script installs Python, Go, Node.js locally under /opt/authentik/.local
- Any changes to pyproject.toml or dependencies should be applied before running the script.

DISCLAIMER:
- This program is provided AS IS and no support will be provided.
- I do not accept any responsibility for your system failing after running the script. Please backup first!!!





