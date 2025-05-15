#!/usr/bin/bash
set -euo pipefail
exec </dev/tty   # ensure we can read from your terminal

# ---- Configuration (edit if you need) ----
IMAGE_PREFIX="registry.tld/conjur-appliance"
# how we detect tarball: latest by version sort
IMAGE_TAR=$(ls conjur-appliance-*.tar.gz 2>/dev/null | sort -V | tail -n1)
# ------------------------------------------

if [[ "$(id -u)" -ne 0 ]]; then
  # not root yet → re-exec under sudo
  echo "🔐 Elevating to root for system prep…"
  exec sudo bash "$0" "$@"
fi

# At this point we're running as root
echo "✔ Running as root: preparing sysctl and directories"

# 1) sysctl tweaks
tee /etc/sysctl.d/conjur.conf >/dev/null <<EOF
net.ipv4.ip_unprivileged_port_start=443
user.max_user_namespaces=28633
EOF
sysctl -p /etc/sysctl.d/conjur.conf

# 2) create mountpoints
USER="thomas"   # hard-code or detect if you prefer
for D in security config backups seeds logs; do
  mkdir -p /opt/cyberark/conjur/$D
  chown "$USER":"$USER" /opt/cyberark/conjur/$D
done

echo "✔ System prep done. Dropping to $USER for Podman steps…"

# Now drop privileges and continue as $USER
exec sudo -u "$USER" bash <<'USER_SCRIPT'
set -euo pipefail
exec </dev/tty

# You're now running as the unprivileged user:
echo "👤 $(whoami) – performing rootless Podman deployment"

# 3) find the tarball & version
IMAGE_TAR=$(ls conjur-appliance-*.tar.gz 2>/dev/null | sort -V | tail -n1)
if [[ -z "$IMAGE_TAR" ]]; then
  echo "❌ No conjur-appliance-*.tar.gz found in $(pwd)"
  exit 1
fi
VERSION=${IMAGE_TAR#conjur-appliance-}
VERSION=${VERSION%.tar.gz}
IMAGE_REF="registry.tld/conjur-appliance:${VERSION}"
HOSTFQDN=$(hostname -f)

# 4) ask for role
read -rp "Conjur role (leader|standby|follower): " ROLE
if [[ ! "$ROLE" =~ ^(leader|standby|follower)$ ]]; then
  echo "❌ Invalid role."
  exit 1
fi

echo
echo "→ Loading image into rootless Podman…"
podman load -i "$IMAGE_TAR"

echo "→ Starting Conjur ($ROLE)…"
COMMON_OPTS=(
  --name "conjur-${ROLE}"
  --hostname "$HOSTFQDN"
  --detach
  --security-opt seccomp=/opt/cyberark/conjur/security/seccomp.json
  --publish 443:443 --publish 444:444
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

podman run "${COMMON_OPTS[@]}" "$IMAGE_REF"

echo "→ Generating systemd user unit…"
USER_HOME=$(eval echo "~$(whoami)")
mkdir -p "$USER_HOME/.config/systemd/user"
podman generate systemd "conjur-${ROLE}" \
  --name --container-prefix="" --separator="" \
  > "$USER_HOME/.config/systemd/user/conjur.service"

echo "→ Enabling user service & linger…"
systemctl --user daemon-reload
systemctl --user enable conjur.service
loginctl enable-linger "$(whoami)"

echo
echo "✅ Conjur ${ROLE^} is now up under rootless Podman."
USER_SCRIPT
