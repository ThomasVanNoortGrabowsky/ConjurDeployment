#!/usr/bin/env bash
set -euo pipefail
exec </dev/tty

echo "=== Conjur Rootless Podman Setup ==="
echo "You'll be prompted only for the role and rootless username."

# --- Interactive Prompts ---
read -rp "1) Role (leader | standby | follower): " ROLE
read -rp "2) Rootless username to create/use: " USERNAME

# --- Defaults (no proxy) ---
IMAGE_PREFIX="registry.tld/conjur-appliance"
IMAGE_TAR=$(ls conjur-appliance-*.tar.gz 2>/dev/null | sort -V | tail -n1)
if [[ -z "$IMAGE_TAR" ]]; then
  echo "❌  No conjur-appliance-*.tar.gz found in $(pwd). Exiting."
  exit 1
fi
VERSION="${IMAGE_TAR#conjur-appliance-}"
VERSION="${VERSION%.tar.gz}"

echo
echo "▶ Starting deployment with:"
echo "   Role     = $ROLE"
echo "   Username = $USERNAME"
echo "   Image    = $IMAGE_TAR (version $VERSION)"
echo

# Determine runtime
if command -v podman &>/dev/null; then
  RUNTIME="podman"
else
  RUNTIME="docker"
fi
echo "Using container runtime: $RUNTIME"
echo

# Step 2: sysctl tweaks
echo "-> Configuring sysctl for rootless Podman…"
cat <<EOF >/etc/sysctl.d/conjur.conf
net.ipv4.ip_unprivileged_port_start=443
user.max_user_namespaces=28633
EOF
sysctl -p /etc/sysctl.d/conjur.conf

# Step 3: Create user
echo "-> Ensuring user '$USERNAME' exists…"
if ! id "$USERNAME" &>/dev/null; then
  useradd -m "$USERNAME"
  echo "   Created user '$USERNAME'"
else
  echo "   User '$USERNAME' already exists"
fi

# Step 4: Folders & ownership
echo "-> Creating Conjur dirs…"
for D in security config backups seeds logs; do
  install -d -o "$USERNAME" -g "$USERNAME" "/opt/cyberark/conjur/$D"
done

# Step 5: Conjur config file
echo "-> Touching conjur.yml…"
sudo -u "$USERNAME" touch /opt/cyberark/conjur/config/conjur.yml
chmod o+x /opt/cyberark/conjur/config
chmod o+r /opt/cyberark/conjur/config/conjur.yml

# Step 6: Load image
echo "-> Loading container image from $IMAGE_TAR…"
$RUNTIME load -i "$IMAGE_TAR"

# Step 10: Run container
echo "-> Starting Conjur container…"
IMG_REF="${IMAGE_PREFIX}:${VERSION}"
HOST_FQDN=$(hostname -f)
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

if [[ "$RUNTIME" == "docker" ]]; then
  docker run "${COMMON_OPTS[@]}" --restart unless-stopped "$IMG_REF"
else
  sudo -u "$USERNAME" podman run "${COMMON_OPTS[@]}" "$IMG_REF"
  echo "-> Generating systemd service for Podman…"
  USER_HOME=$(eval echo "~$USERNAME")
  mkdir -p "$USER_HOME/.config/systemd/user"
  sudo -u "$USERNAME" podman generate systemd "conjur-${ROLE}" \
    --name --container-prefix="" --separator="" \
    > "$USER_HOME/.config/systemd/user/conjur.service"
  su - "$USERNAME" -c "systemctl --user enable conjur.service"
  echo "-> Enabling linger for $USERNAME…"
  loginctl enable-linger "$USERNAME"
fi

echo
echo "✅ Conjur ${ROLE^} ('conjur-${ROLE}') is now up under $RUNTIME."
