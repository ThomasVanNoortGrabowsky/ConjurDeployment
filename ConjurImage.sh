#!/usr/bin/env bash
set -euo pipefail

# 0) Ensure we're root
if [[ $EUID -ne 0 ]]; then
  echo "Please run this script with sudo: sudo $0"
  exit 1
fi

# 1) Remember the original user & working directory
ORIG_USER="${SUDO_USER:?Must run via sudo}"
WORKDIR="$(pwd)"
ORIG_HOME="$(eval echo "~$ORIG_USER")"

# 2) Prompt for Conjur role
read -rp "Conjur role (leader | standby | follower): " ROLE
if [[ ! "$ROLE" =~ ^(leader|standby|follower)$ ]]; then
  echo "Invalid role – must be one of leader, standby, or follower."
  exit 1
fi

# 3) Find the Conjur appliance tarball
IMAGE_TAR=$(ls conjur-appliance-*.tar.gz 2>/dev/null | sort -V | tail -n1)
if [[ -z "$IMAGE_TAR" ]]; then
  echo "No conjur-appliance-*.tar.gz found in $WORKDIR"
  exit 1
fi
VERSION=${IMAGE_TAR#conjur-appliance-}
VERSION=${VERSION%.tar.gz}
IMAGE_REF="registry.tld/conjur-appliance:${VERSION}"
HOSTFQDN=$(hostname -f)

echo
echo "→ SYSCTL & /OPT prep (as root)…"

# 4) Enable low ports & increase user namespaces for rootless Podman
cat >/etc/sysctl.d/conjur.conf <<EOF
net.ipv4.ip_unprivileged_port_start=443
user.max_user_namespaces=28633
EOF
sysctl -p /etc/sysctl.d/conjur.conf

# 5) Create mount dirs under /opt and chown to your user
for d in security config backups seeds logs; do
  mkdir -p /opt/cyberark/conjur/"$d"
  chown "$ORIG_USER":"$ORIG_USER" /opt/cyberark/conjur/"$d"
done

echo "✔ System prep done. Now running rootless Podman as $ORIG_USER…"
echo

# 6) Switch to your user for the Podman steps
su - "$ORIG_USER" -c "bash -eux <<'EOF'
cd \"$WORKDIR\"

# Load the image
echo '→ Loading image: $IMAGE_TAR'
podman load -i \"$IMAGE_TAR\"

# Build run options
COMMON_OPTS=(
  --name \"conjur-$ROLE\"
  --hostname \"$HOSTFQDN\"
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

# extra ports for leader/standby
if [[ \"$ROLE\" =~ ^(leader|standby)\$ ]]; then
  COMMON_OPTS+=(--publish 5432:5432 --publish 1999:1999)
fi

# backup volume only for leader
if [[ \"$ROLE\" == \"leader\" ]]; then
  COMMON_OPTS+=(--volume /opt/cyberark/conjur/backups:/opt/conjur/backup:z)
fi

echo '→ Starting Conjur container'
podman run \"\${COMMON_OPTS[@]}\" \"$IMAGE_REF\"

# systemd user unit
echo '→ Generating systemd user service'
mkdir -p \"$HOME/.config/systemd/user\"
podman generate systemd \"conjur-$ROLE\" --name --container-prefix='' --separator='' \
  > \"$HOME/.config/systemd/user/conjur.service\"

echo '→ Enabling systemd user service & linger'
systemctl --user daemon-reload
systemctl --user enable conjur.service
loginctl enable-linger \"$ORIG_USER\"

echo
echo '✅ Conjur $ROLE is now running under rootless Podman!'
EOF"

echo "All done. You can verify with: podman ps"
