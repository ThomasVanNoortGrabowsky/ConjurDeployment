#!/usr/bin/env bash
# deploy-conjur.sh — end-to-end rootless Podman deployment of Conjur Enterprise

set -euo pipefail
IFS=$'\n\t'

########################################
# 1) Define paths & filenames
########################################

# ZIP on VMware shared folder (spaces handled)
SHARED_ZIP="/mnt/hgfs/File_Sharing/Conjur Enterprise_13.6_17.474379609528.zip"

# Where to unpack and build the appliance
DEPLOY_DIR="$HOME/ConjurDeployment/Conjur Enterprise/Conjur Enterprise Appliance"

# Name of the rootless user to run Podman
CONJUR_USER="${CONJUR_USER:-conjurless}"

# Version tag (optional override)
IMAGE_TAG="${IMAGE_TAG:-v13.6.0}"

########################################
# 2) Unzip the appliance
########################################

echo "==> Unpacking appliance ZIP to:"
echo "    $DEPLOY_DIR"
mkdir -p "$DEPLOY_DIR"
unzip -o "$SHARED_ZIP" -d "$DEPLOY_DIR"

########################################
# 3) Sysctl tuning for rootless Podman
########################################

echo "==> Writing /etc/sysctl.d/conjur.conf"
sudo tee /etc/sysctl.d/conjur.conf > /dev/null <<EOF
# Allow low port numbers for rootless Podman
net.ipv4.ip_unprivileged_port_start=443
# Increase max user namespaces
user.max_user_namespaces=28633
EOF

echo "==> Reloading sysctl settings"
sudo sysctl -p /etc/sysctl.d/conjur.conf

########################################
# 4) Create rootless user if needed
########################################

if ! id "$CONJUR_USER" &>/dev/null; then
  echo "==> Creating rootless user: $CONJUR_USER"
  sudo useradd -m -r -s /usr/sbin/nologin "$CONJUR_USER"
fi

########################################
# 5) Prepare Conjur host folders
########################################

echo "==> Creating Conjur directories under /opt/cyberark/conjur"
sudo mkdir -p /opt/cyberark/conjur/{security,config,backups,seeds,logs}
sudo chown -R "$CONJUR_USER":"$CONJUR_USER" /opt/cyberark/conjur

########################################
# 6) Create conjur.yml and set perms
########################################

echo "==> Touching conjur.yml and setting permissions"
sudo -u "$CONJUR_USER" touch /opt/cyberark/conjur/config/conjur.yml
sudo chmod o+x /opt/cyberark/conjur/config
sudo chmod o+r /opt/cyberark/conjur/config/conjur.yml

########################################
# 7) Place seccomp.json (if provided)
########################################

# If your ZIP contained a seccomp.json, copy it:
if [[ -f "$DEPLOY_DIR/security/seccomp.json" ]]; then
  echo "==> Installing seccomp.json"
  sudo install -m 0644 "$DEPLOY_DIR/security/seccomp.json" /opt/cyberark/conjur/security/seccomp.json
else
  echo "Warning: no seccomp.json found in ZIP — please add /opt/cyberark/conjur/security/seccomp.json manually"
fi

########################################
# 8) Build the appliance tarball
########################################

echo "==> Running your tar-creation script in $DEPLOY_DIR"
pushd "$DEPLOY_DIR" >/dev/null
BUILD_SCRIPT=$(find . -maxdepth 1 -type f -executable -name '*tar*.sh' | head -n1 || true)
if [[ -n "$BUILD_SCRIPT" ]]; then
  echo "→ $BUILD_SCRIPT"
  ./"$BUILD_SCRIPT"
else
  echo "Error: no '*tar*.sh' script found in $DEPLOY_DIR" >&2
  exit 1
fi

echo "==> Locating conjur-appliance-*.tar.gz"
TARBALL=$(find . -maxdepth 1 -type f -name 'conjur-appliance-*.tar.gz' | sort | tail -n1 || true)
if [[ -z "$TARBALL" ]]; then
  echo "Error: tarball not found after build" >&2
  exit 1
fi
TARBALL_PATH="$DEPLOY_DIR/$TARBALL"
popd >/dev/null

########################################
# 9) Load the image into Podman
########################################

echo "==> Loading appliance image into Podman"
sudo -u "$CONJUR_USER" podman load -i "$TARBALL_PATH"

########################################
# 10) Run the Conjur Leader container
########################################

echo "==> Starting Conjur Leader container via Podman"
sudo -u "$CONJUR_USER" podman run -d \
  --name conjur-leader \
  --hostname "$(hostname -f)" \
  --security-opt seccomp=/opt/cyberark/conjur/security/seccomp.json \
  --publish 443:443 \
  --publish 444:444 \
  --publish 5432:5432 \
  --cap-add AUDIT_WRITE \
  --log-driver journald \
  --volume /opt/cyberark/conjur/config:/etc/conjur/config:z \
  --volume /opt/cyberark/conjur/security:/opt/cyberark/conjur/security:z \
  --volume /opt/cyberark/conjur/backups:/opt/conjur/backup:z \
  --volume /opt/cyberark/conjur/logs:/var/log/conjur:z \
  conjur-appliance:"$IMAGE_TAG"

########################################
# 11) Generate systemd unit & enable linger
########################################

echo "==> Generating systemd unit for conjur-leader"
sudo -u "$CONJUR_USER" mkdir -p "$HOME/.config/systemd/user"
sudo -u "$CONJUR_USER" podman generate systemd --name conjur-leader > "$HOME/.config/systemd/user/conjur.service"

echo "==> Enabling user systemd service and linger"
sudo -u "$CONJUR_USER" systemctl --user daemon-reload
sudo -u "$CONJUR_USER" systemctl --user enable conjur.service
sudo loginctl enable-linger "$CONJUR_USER"

########################################
# 12) Finished
########################################

echo
echo "✅  Conjur Enterprise Leader is now running rootless under user '$CONJUR_USER'."
echo "    Access it at: https://$(hostname -f)"
echo
