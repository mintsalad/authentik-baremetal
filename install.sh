#!/usr/bin/env bash
set -euo pipefail
set -x

: "${ARCH:=amd64}"
BASE_DIR=/opt/authentik
DOTLOCAL=$BASE_DIR/.local
BIN_DIR="${DOTLOCAL}/bin"
SRC_DIR=$BASE_DIR/src
VENV="$BASE_DIR/.venv"
PYTHON_VERSION="3.13.0"
PYTHON_BIN="$DOTLOCAL/bin/python3.13"

export PATH="$BIN_DIR:$PATH"

#############################################
# 1. Prerequisites
#############################################
sudo apt-get update -y
sudo apt-get install -y \
  build-essential git curl wget unzip pkg-config libssl-dev libffi-dev \
  zlib1g-dev libbz2-dev libreadline-dev libsqlite3-dev liblzma-dev \
  uuid-dev python3-venv python3-distutils python3-dev gcc make cmake \
  openssl npm nodejs golang jq systemd libkrb5-dev libsasl2-dev \
  libldap2-dev libpq-dev libmariadb-dev-compat libmariadb-dev \
  default-libmysqlclient-dev libxml2-dev libxslt1-dev libjpeg-dev tk-dev \
  libgdbm-dev libncurses5-dev libncursesw5-dev

#############################################
# 2. Disk space check (10 GB minimum)
#############################################
REQUIRED_MB=10240
AVAILABLE_MB=$(df -Pm "$BASE_DIR" | awk 'NR==2 {print $4}')

if [ "$AVAILABLE_MB" -lt "$REQUIRED_MB" ]; then
    echo "❌ Not enough disk space in $BASE_DIR"
    echo "Required: ${REQUIRED_MB} MB, Available: ${AVAILABLE_MB} MB"
    exit 1
else
    echo "✅ Disk space check passed: ${AVAILABLE_MB} MB available"
fi

#############################################
# 3. Install Python 3.13 if missing
#############################################
if [ ! -x "$PYTHON_BIN" ]; then
    cd "$BASE_DIR"
    wget -qO- "https://www.python.org/ftp/python/${PYTHON_VERSION}/Python-${PYTHON_VERSION}.tgz" | tar -zxf -
    cd "Python-${PYTHON_VERSION}"
    ./configure --enable-optimizations --prefix="$DOTLOCAL"
    make altinstall
    cd ..
    rm -rf "Python-${PYTHON_VERSION}"
fi

#############################################
# 4. Install yq if missing
#############################################
if ! command -v yq &>/dev/null; then
    YQ_LATEST=$(wget -qO- "https://api.github.com/repos/mikefarah/yq/releases/latest" | grep -Po '"tag_name": "\K.*?(?=")')
    wget -qO "$BIN_DIR/yq" "https://github.com/mikefarah/yq/releases/download/${YQ_LATEST}/yq_linux_${ARCH}"
    chmod +x "$BIN_DIR/yq"
fi

#############################################
# 5. Node.js via NVM
#############################################
export NVM_DIR="$HOME/.nvm"
if [ ! -s "$NVM_DIR/nvm.sh" ]; then
    curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
fi
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"

NODE_MAJOR=24
if ! command -v node >/dev/null 2>&1 || [[ "$(node -v | cut -d'v' -f2 | cut -d. -f1)" -lt $NODE_MAJOR ]]; then
    nvm install "$NODE_MAJOR"
fi
nvm use "$NODE_MAJOR"

#############################################
# 6. Go install/upgrade
#############################################
REQUIRED_GO="1.23.0"
GO_TAR="go${REQUIRED_GO}.linux-${ARCH}.tar.gz"
if ! command -v go >/dev/null 2>&1 || [[ "$(go version | awk '{print $3}' | cut -c3-)" != "$REQUIRED_GO" ]]; then
    echo "[Go] Installing Go $REQUIRED_GO..."
    wget -q "https://go.dev/dl/${GO_TAR}" -O "$GO_TAR"
    sudo rm -rf /usr/local/go
    sudo tar -C /usr/local -xzf "$GO_TAR"
    rm -f "$GO_TAR"
fi
export PATH="/usr/local/go/bin:$PATH"

#############################################
# 7. Authentik source
#############################################
if [ ! -d "$SRC_DIR/.git" ]; then
    git clone https://github.com/goauthentik/authentik.git "$SRC_DIR"
else
    cd "$SRC_DIR"
    git pull --ff-only
fi
cd "$SRC_DIR"

#############################################
# 8. Python venv + Poetry
#############################################
if [ ! -d "$VENV" ]; then
    "$PYTHON_BIN" -m venv "$VENV"
fi

curl -sS https://bootstrap.pypa.io/get-pip.py | "$VENV/bin/python"

"$VENV/bin/pip" install --no-cache-dir poetry poetry-plugin-export

#############################################
# 8a. Patch django-dramatiq-postgres dependency
#############################################
PYPROJECT_FILE="$SRC_DIR/pyproject.toml"
if grep -q "django-dramatiq-postgres" "$PYPROJECT_FILE"; then
    echo "[Poetry] Patching django-dramatiq-postgres to use GitHub repository"
    sed -i 's|django-dramatiq-postgres|django-dramatiq-postgres = { git = "https://github.com/bmwant/django-dramatiq-postgres.git" }|' "$PYPROJECT_FILE"
fi

#############################################
# 8b. Lock and install dependencies
#############################################
"$VENV/bin/poetry" env use "$PYTHON_BIN"

if [ ! -f poetry.lock ]; then
    "$VENV/bin/poetry" lock || true
fi

"$VENV/bin/poetry" install --no-root || true

#############################################
# 9. Frontend build (website + web)
#############################################
for frontend in website web; do
    cd "$SRC_DIR/$frontend" || continue
    npm install --legacy-peer-deps
    npm audit fix || true
    npm run build
done

#############################################
# 10. Build authentik server
#############################################
cd "$SRC_DIR"
go build -o "$SRC_DIR/authentik-server" "$SRC_DIR/cmd/server/"

#############################################
# 11. Systemd services
#############################################
sudo tee /etc/systemd/system/authentik-server.service >/dev/null <<EOF
[Unit]
Description=Authentik Server (Web/API/SSO)

[Service]
User=$(whoami)
WorkingDirectory=$SRC_DIR
ExecStart=$VENV/bin/python3 -m lifecycle.migrate && $SRC_DIR/authentik-server
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

sudo tee /etc/systemd/system/authentik-worker.service >/dev/null <<EOF
[Unit]
Description=Authentik Worker (background tasks)

[Service]
User=$(whoami)
WorkingDirectory=$SRC_DIR
ExecStart=$VENV/bin/python3 -m lifecycle.migrate && celery -A authentik.root.celery worker -Ofair --max-tasks-per-child=1 --autoscale 3,1 -E -B -s /tmp/celerybeat-schedule -Q authentik,authentik_scheduled,authentik_events
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

#############################################
# 12. Configuration
#############################################
mkdir -p "$BASE_DIR"/{templates,certs}
CONFIG_FILE="$SRC_DIR/.local.env.yml"

cp "$SRC_DIR/authentik/lib/default.yml" "$CONFIG_FILE"
cp -r "$SRC_DIR/blueprints" "$BASE_DIR/blueprints"

yq -i ".secret_key = \"$(openssl rand -hex 32)\"" "$CONFIG_FILE"
yq -i ".error_reporting.enabled = false" "$CONFIG_FILE"
yq -i ".disable_update_check = true" "$CONFIG_FILE"
yq -i ".disable_startup_analytics = true" "$CONFIG_FILE"
yq -i ".email.template_dir = \"$BASE_DIR/templates\"" "$CONFIG_FILE"
yq -i ".cert_discovery_dir = \"$BASE_DIR/certs\"" "$CONFIG_FILE"
yq -i ".blueprints_dir = \"$BASE_DIR/blueprints\"" "$CONFIG_FILE"
yq -i ".geoip = \"/var/lib/GeoIP/GeoLite2-City.mmdb\"" "$CONFIG_FILE"
