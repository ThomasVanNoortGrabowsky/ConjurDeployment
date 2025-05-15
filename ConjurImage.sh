#!/usr/bin/env bash
set -euo pipefail

# Ensure reads come from your TTY (even under sudo)
exec </dev/tty

echo "=== Conjur Rootless Podman Setup ==="

# 1) Ask for the role
read -rp "1) Role (leader | standby | follower): " ROLE
if [[ ! "$ROLE" =~ ^(leader|standby|follower)$ ]]; then
  echo "❌ Invalid role. Must be: leader, standby or follower."
  exit 1
fi

# 2) Derive current user
USERNAME=$(whoami)
echo "→ Running as user: $USERNAME (will be your rootless Podman user)"

# 3) Defaults (no proxy)
IMAGE_PREFIX="registry.tld/conjur-appliance"
IMAGE_TAR=$(ls conjur-appliance-*.tar.gz 2>/dev/null | sort -V | tail -n1)
if [[ -z "$IMAGE_TAR" ]]; then
  echo "❌ No conjur-appliance-*.tar.gz found in $(pwd)."
  exit 1
fi
VERSION=${IMAGE_TAR#conjur-appliance-}
VERSION=${VERSION%.tar.gz}
HOSTFQDN=$(hostname -f)

echo
echo "Configuration:"
echo "  ROLE         = $ROLE"
echo "  USERNAME     = $USERNAME"
echo "  IMAGE_PREFIX = $IMAGE_PREFIX"
echo "  IMAGE_TAR    = $IMAGE_TAR"
echo "  VERSION      = $VERSION"
echo "  HOST FQDN    = $HOSTFQDN"
echo

# 4) Make sure Podman is available
if ! command -v podman &>/dev/null; then
  echo "❌ podman not found. Install Podman first."
  exit 1
fi

# 5) Step 2: sysctl tweaks for rootless ports & namespaces
echo "→ Configuring sysctl for rootless Podman via sudo…"
sudo tee /etc/sysctl.d/conjur.conf >/dev/null <<EOF
# Allow low port numbers for rootless Podman
net.ipv4.ip_unprivileged_port_start=443
# Increase max user namespaces
user.max_user_namespaces=28633
EOF
sudo sysctl -p /etc/sysctl.d/conjur.conf

# 6) Step 4: create Conjur folders under /opt and chown to you
echo "→ Creating /opt/cyberark/conjur folders via sudo…"
for D in security config backups seeds logs; do
  sudo mkdir -p /opt/cyberark/conjur/$D
  sudo chown "$USERNAME":"$USERNAME" /opt/cyberark/conjur/$D
done

# 7) Step 5: create empty conjur.yml as your user
echo "→ Touching conjur.yml (so Podman can mount it)…"
sudo -u "$USERNAME" touch /opt/cyberark/conjur/config/conjur.yml
sudo chmod o+x /opt/cyberark/conjur/config
sudo chmod o+r /opt/cyberark/conjur/config/conjur.yml

# 8) Step 6: load the image into your rootless Podman
echo "→ Loading Conjur image into rootless Podman…"
podman load -i "$IMAGE_TAR"

# 9) Step 10: build common podman run options
echo "→ Starting Conjur ($ROLE) container via rootless Podman…"
IMG_REF="${IMAGE_PREFIX}:${VERSION}"
COMMON_OPTS=(
  --name "conjur-${ROLE}"
  --hostname "$HOSTFQDN"
  --detach
  --security-opt seccomp=/opt/cyberark/conjur/security/seccomp.json
  --publish 443:443
  --publish 444:444
  --cap-add AUDIT_WRITE
  --log-driver journald
  --volume /opt/cyberark/conjur/config:/etc/conjur/config:z
  --volume /opt/cyberark/conjur/security:/opt/cyberark/conjur/security:z
  --volume /opt/cyberark/conjur/logs:/var/log/conjur:z
)
if [[ "$ROLE" =~ ^(leader|standby)$ ]]; then
  COMMON_OPTS+=(--publish 5432:5432 --publish 1999:1999)
fi
if [[ "$ROLE" == "leader" ]]; then
  COMMON_OPTS+=(--volume /opt/cyberark/conjur/backups:/opt/conjur/backup:z)
fi

podman run "${COMMON_OPTS[@]}" "$IMG_REF"

# 10) Step 11: generate & enable your per-user systemd service
echo "→ Generating systemd service (user) for Podman auto-start…"
USER_HOME=$(eval echo "~$USERNAME")
mkdir -p "$USER_HOME/.config/systemd/user"
podman generate systemd "conjur-${ROLE}" \
  --name --container-prefix="" --separator="" \
  > "$USER_HOME/.config/systemd/user/conjur.service"

echo "→ Enabling systemd user service…"
su - "$USERNAME" -c "systemctl --user daemon-reload && systemctl --user enable conjur.service"

# 11) Step 12: enable linger so the Podman service survives logout
echo "→ Enabling linger for user $USERNAME…"
loginctl enable-linger "$USERNAME"

echo
echo "✅  Conjur ${ROLE^} ('conjur-${ROLE}') is now running under rootless Podman."
echo "    You can check with: podman ps"
