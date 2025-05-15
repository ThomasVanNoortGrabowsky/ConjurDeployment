#!/usr/bin/env bash
set -euo pipefail

# Ensure reads come from your TTY even under sudo
exec </dev/tty

echo "=== Conjur Rootless Podman Setup ==="

# 1) Prompt for Conjur role
read -rp "1) Role (leader | standby | follower): " ROLE
if [[ ! "$ROLE" =~ ^(leader|standby|follower)$ ]]; then
  echo "❌ Invalid role. Must be: leader, standby or follower."
  exit 1
fi

# 2) Use current user as rootless Podman user
USERNAME="$(whoami)"
echo "→ Running as user: $USERNAME"

# 3) Auto-discover the latest appliance tarball and version
IMAGE_TAR=$(ls conjur-appliance-*.tar.gz 2>/dev/null | sort -V | tail -n1)
if [[ -z "$IMAGE_TAR" ]]; then
  echo "❌ No conjur-appliance-*.tar.gz found in $(pwd)."
  exit 1
fi
VERSION="${IMAGE_TAR#conjur-appliance-}"
VERSION="${VERSION%.tar.gz}"
IMAGE_PREFIX="registry.tld/conjur-appliance"
HOSTFQDN="$(hostname -f)"

echo
echo "Configuration:"
echo "  ROLE         = $ROLE"
echo "  USERNAME     = $USERNAME"
echo "  IMAGE_TAR    = $IMAGE_TAR"
echo "  VERSION      = $VERSION"
echo "  IMAGE_REF    = ${IMAGE_PREFIX}:${VERSION}"
echo "  HOST FQDN    = $HOSTFQDN"
echo

read -rp "Proceed with these settings? [Y/n]: " CONFIRM
if [[ "$CONFIRM" =~ ^[Nn]$ ]]; then
  echo "Aborted."
  exit 0
fi

# 4) Prime sudo credentials once
echo
echo "🔐 You may be prompted for your sudo password below."
sudo -v

# 5) Step 2: sysctl tweaks for rootless Podman
echo "→ Configuring /etc/sysctl.d/conjur.conf"
sudo tee /etc/sysctl.d/conjur.conf >/dev/null <<EOF
# Allow low port numbers for rootless Podman
net.ipv4.ip_unprivileged_port_start=443
# Increase max user namespaces
user.max_user_namespaces=28633
EOF
sudo sysctl -p /etc/sysctl.d/conjur.conf

# 6) Step 4: Create /opt/cyberark/conjur folders & chown to you
echo "→ Creating Conjur directories under /opt"
for D in security config backups seeds logs; do
  sudo mkdir -p /opt/cyberark/conjur/"$D"
  sudo chown "$USERNAME":"$USERNAME" /opt/cyberark/conjur/"$D"
done

# 7) Step 5: Touch conjur.yml and fix perms
echo "→ Preparing conjur.yml"
sudo -u "$USERNAME" touch /opt/cyberark/conjur/config/conjur.yml
sudo chmod o+x /opt/cyberark/conjur/config
sudo chmod o+r /opt/cyberark/conjur/config/conjur.yml

# 8) Step 6: Load the Conjur appliance image into rootless Podman
echo "→ Loading Conjur image ($IMAGE_TAR)"
podman load -i "$IMAGE_TAR"

# 9) Step 10: Run the Conjur container in rootless Podman
echo "→ Starting Conjur container (role=$ROLE)"
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

# 10) Step 11: Generate & enable systemd user service
echo "→ Generating systemd unit for ${USERNAME}"
USER_HOME="$(eval echo "~$USERNAME")"
mkdir -p "$USER_HOME/.config/systemd/user"
podman generate systemd "conjur-${ROLE}" \
  --name --container-prefix="" --separator="" \
  > "$USER_HOME/.config/systemd/user/conjur.service"
su - "$USERNAME" -c "systemctl --user daemon-reload && systemctl --user enable conjur.service"

# 11) Step 12: Enable linger so your service survives logout
echo "→ Enabling linger for user $USERNAME"
loginctl enable-linger "$USERNAME"

echo
echo "✅ Conjur ${ROLE^} ('conjur-${ROLE}') is running under rootless Podman."
echo "   Check with: podman ps"
