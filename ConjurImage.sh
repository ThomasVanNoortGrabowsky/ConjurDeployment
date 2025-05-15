#!/usr/bin/env bash
set -euo pipefail

echo "=== Conjur Rootless Podman Setup ==="
echo "You'll be prompted for the role and rootless username only."

# --- Interactive Prompts ---
read -rp "1) Role (leader | standby | follower): " ROLE
read -rp "2) Rootless username to create/use: " USERNAME

# Validate inputs
if [[ -z "$ROLE" || -z "$USERNAME" ]]; then
  echo "☠️  Both role and username are required. Exiting."
  exit 1
fi

# --- Defaults ---
IMAGE_PREFIX="registry.tld/conjur-appliance"
# pick the highest-version tarball in cwd matching conjur-appliance-*.tar.gz
IMAGE_TAR=$(ls conjur-appliance-*.tar.gz 2>/dev/null | sort -V | tail -n1)
if [[ -z "$IMAGE_TAR" ]]; then
  echo "❌  No conjur-appliance-*.tar.gz found in $(pwd)."
  exit 1
fi
# derive version from filename: conjur-appliance-<version>.tar.gz
VERSION="${IMAGE_TAR#conjur-appliance-}"
VERSION="${VERSION%.tar.gz}"

echo
echo "Configuration:"
echo "  ROLE         = $ROLE"
echo "  USERNAME     = $USERNAME"
echo "  IMAGE_PREFIX = $IMAGE_PREFIX"
echo "  IMAGE_TAR    = $IMAGE_TAR"
echo "  VERSION      = $VERSION"
echo
read -rp "Proceed with these settings? [y/N]: " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
  echo "Aborted by user."
  exit 0
fi

# Determine container runtime
if command -v podman &>/dev/null; then
  RUNTIME="podman"
else
  RUNTIME="docker"
fi
echo "Using runtime: $RUNTIME"

# Step 2: sysctl tweaks for rootless Podman
cat <<EOF >/etc/sysctl.d/conjur.conf
# Allow low port numbers for rootless Podman
net.ipv4.ip_unprivileged_port_start=443
# Increase max user namespaces
user.max_user_namespaces=28633
EOF
sysctl -p /etc/sysctl.d/conjur.conf

# Step 3: Create rootless user if absent
if ! id "$USERNAME" &>/dev/null; then
  useradd -m "$USERNAME"
  echo "Created user '$USERNAME'."
fi

# Step 4: Create Conjur system folders & chown
for DIR in security config backups seeds logs; do
  mkdir -p /opt/cyberark/conjur/$DIR
  chown "$USERNAME":"$USERNAME" /opt/cyberark/conjur/$DIR
done

# Step 5: Create conjur.yml and set perms
sudo -u "$USERNAME" touch /opt/cyberark/conjur/config/conjur.yml
chmod o+x /opt/cyberark/conjur/config
chmod o+r /opt/cyberark/conjur/config/conjur.yml

# Step 6: Load the Conjur appliance image
echo "Loading image from '$IMAGE_TAR'..."
$RUNTIME load -i "$IMAGE_TAR"

# Step 10: Start the Conjur container
IMG_REF="${IMAGE_PREFIX}:${VERSION}"
HOST_FQDN=$(hostname -f)

COMMON_OPTS=(
  --name "conjur-${ROLE}"
  --hostname "$HOST_FQDN"
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

# Leader/standby extra ports
if [[ "$ROLE" =~ ^(leader|standby)$ ]]; then
  COMMON_OPTS+=(--publish 5432:5432 --publish 1999:1999)
fi
# Leader backup volume
if [[ "$ROLE" == "leader" ]]; then
  COMMON_OPTS+=(--volume /opt/cyberark/conjur/backups:/opt/conjur/backup:z)
fi

if [[ "$RUNTIME" == "docker" ]]; then
  docker run "${COMMON_OPTS[@]}" --restart unless-stopped "$IMG_REF"
else
  # Rootless Podman
  sudo -u "$USERNAME" podman run "${COMMON_OPTS[@]}" "$IMG_REF"

  # Step 11: Generate & enable systemd user service
  USER_HOME=$(eval echo "~$USERNAME")
  mkdir -p "$USER_HOME/.config/systemd/user"
  sudo -u "$USERNAME" podman generate systemd "conjur-${ROLE}" \
    --name --container-prefix="" --separator="" \
    > "$USER_HOME/.config/systemd/user/conjur.service"
  su - "$USERNAME" -c "systemctl --user enable conjur.service"

  # Step 12: Persist user processes
  loginctl enable-linger "$USERNAME"
fi

echo
echo "🎉 Conjur ${ROLE^} ('conjur-${ROLE}') is up with $RUNTIME."
