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

# 3) Unzip the Conjur appliance image from the VMware shared folder
ZIP_PATH="/mnt/hgfs/File_Sharing/Conjur Enterprise_13.6_1747379609528.zip"
if [[ ! -f "$ZIP_PATH" ]]; then
  echo "ERROR: ZIP file not found at $ZIP_PATH"
  exit 1
fi
echo "→ Unzipping Conjur appliance image from shared folder…"
unzip -o "$ZIP_PATH" -d "$WORKDIR"

# 4) Find the extracted TAR.GZ
IMAGE_TAR=$(ls "$WORKDIR"/conjur-appliance-*.tar.gz 2>/dev/null | sort -V | tail -n1 || true)
if [[ -z "$IMAGE_TAR" ]]; then
  echo "No conjur-appliance-*.tar.gz found in $WORKDIR after unzip"
  exit 1
fi
VERSION=${IMAGE_TAR##*/conjur-appliance-}
VERSION=${VERSION%.tar.gz}
IMAGE_REF="registry.tld/conjur-appliance:${VERSION}"
HOSTFQDN=$(hostname -f)

echo
echo "→ STEP 2: Enable low ports & increase user namespaces…"
cat >/etc/sysctl.d/conjur.conf <<EOF
# Allow low port number for rootless Podman:
net.ipv4.ip_unprivileged_port_start=443
# Increase max user namespaces:
user.max_user_namespaces=28633
EOF
sysctl -p /etc/sysctl.d/conjur.conf

echo
echo "→ STEP 3 & 4: Create rootless user (if needed) and system folders…"
# (Assumes $ORIG_USER already exists and meets Podman UID/GID requirements)
for d in security config backups seeds logs; do
  mkdir -p /opt/cyberark/conjur/"$d"
  chown "$ORIG_USER":"$ORIG_USER" /opt/cyberark/conjur/"$d"
done

echo
echo "→ STEP 5: Create empty conjur.yml and set permissions…"
touch /opt/cyberark/conjur/config/conjur.yml
chmod o+x /opt/cyberark/conjur/config
chmod o+r /opt/cyberark/conjur/config/conjur.yml
chown "$ORIG_USER":"$ORIG_USER" /opt/cyberark/conjur/config/conjur.yml

echo
echo "✔ System prep complete. Now running rootless Podman as $ORIG_USER…"
echo

# 6) Switch to your user for the Podman steps
su - "$ORIG_USER" -c "bash -eux <<'EOF'
cd \"$WORKDIR\"

# STEP 6: Load the image
echo '→ Loading image: ${IMAGE_TAR##*/}'
podman load -i \"$IMAGE_TAR\"

# STEP 7 & 10: Build run options and start Conjur
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

if [[ \"$ROLE\" =~ ^(leader|standby)\$ ]]; then
  COMMON_OPTS+=(--publish 5432:5432 --publish 1999:1999)
fi

if [[ \"$ROLE\" == \"leader\" ]]; then
  COMMON_OPTS+=(--volume /opt/cyberark/conjur/backups:/opt/conjur/backup:z)
fi

echo '→ Starting Conjur container'
podman run \"\${COMMON_OPTS[@]}\" \"$IMAGE_REF\"

# STEP 11: Generate and enable systemd user service
echo '→ Generating systemd user service'
mkdir -p \"\$HOME/.config/systemd/user\"
podman generate systemd \"conjur-$ROLE\" --name --container-prefix='' --separator='' \
  > \"\$HOME/.config/systemd/user/conjur.service\"
systemctl --user daemon-reload
systemctl --user enable conjur.service

# STEP 12: Persist user processes after logout
loginctl enable-linger \"$ORIG_USER\"

echo
echo '✅ Conjur $ROLE is now running under rootless Podman!'
EOF"

echo
echo "All done. Verify with: podman ps"
