#!/usr/bin/env bash
set -euo pipefail

# Ensure our reads come from the terminal, even under sudo
exec </dev/tty

echo "=== Conjur Rootless Podman Deployment ==="
read -rp "1) Role (leader | standby | follower): " ROLE

# Who am I?
USERNAME=$(id -un)
echo "Deploying as user: $USERNAME"
echo

# ——— Step 2: sysctl tweaks for rootless Podman ———
echo "→ Configuring kernel for unprivileged ports & namespaces…"
sudo tee /etc/sysctl.d/conjur.conf >/dev/null <<EOF
# Allow low ports for rootless Podman
net.ipv4.ip_unprivileged_port_start=443
# Increase max user namespaces
user.max_user_namespaces=28633
EOF
sudo sysctl -p /etc/sysctl.d/conjur.conf
echo

# ——— Step 4: Create Conjur system folders ———
echo "→ Creating /opt/cyberark/conjur/{security,config,backups,seeds,logs}…"
for D in security config backups seeds logs; do
  sudo mkdir -p /opt/cyberark/conjur/$D
  sudo chown "$USERNAME":"$USERNAME" /opt/cyberark/conjur/$D
done
echo

# ——— Step 5: Create an empty conjur.yml ———
echo "→ Touching conjur.yml and fixing perms…"
sudo -u "$USERNAME" touch /opt/cyberark/conjur/config/conjur.yml
sudo chmod o+x /opt/cyberark/conjur/config
sudo chmod o+r /opt/cyberark/conjur/config/conjur.yml
echo

# ——— Step 6: Load the Conjur appliance image ———
# Finds the latest tarball in your cwd matching conjur-appliance-*.tar.gz
IMAGE_TAR=$(ls conjur-appliance-*.tar.gz 2>/dev/null | sort -V | tail -n1)
if [[ -z "$IMAGE_TAR" ]]; then
  echo "❌  No conjur-appliance-*.tar.gz found in $(pwd). Aborting."
  exit 1
fi
VERSION="${IMAGE_TAR#conjur-appliance-}"
VERSION="${VERSION%.tar.gz}"
IMAGE_PREFIX="registry.tld/conjur-appliance"
echo "→ Loading image $IMAGE_TAR into rootless Podman…"
podman load -i "$IMAGE_TAR"
echo

# ——— Step 10: Start the Conjur container rootless ———
HOST_FQDN=$(hostname -f)
IMG_REF="${IMAGE_PREFIX}:${VERSION}"
echo "→ Running Conjur ${ROLE^} as rootless Podman container…"

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
echo

# ——— Step 11: Generate & enable systemd user‐service ———
echo "→ Generating systemd unit for $USERNAME…"
USER_HOME=$(eval echo "~$USERNAME")
mkdir -p "$USER_HOME/.config/systemd/user"
podman generate systemd "conjur-${ROLE}" \
  --name --container-prefix="" --separator="" \
  > "$USER_HOME/.config/systemd/user/conjur.service"

echo "→ Enabling user service and linger…"
sudo loginctl enable-linger "$USERNAME"
su - "$USERNAME" -c "systemctl --user enable conjur.service"

echo
echo "✅ Conjur ${ROLE^} is now running under rootless Podman."
echo "   To check: podman ps | grep conjur-${ROLE}"
echo "   Logs:   journalctl -u podman-conjur-${ROLE}.service --user"
