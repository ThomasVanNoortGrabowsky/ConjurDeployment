#!/usr/bin/env bash
set -euo pipefail
exec </dev/tty    # ensure prompt input works under sudo

# ——– CONFIGURATION ——–
# If you need to override the registry, change this:
IMAGE_PREFIX="registry.tld/conjur-appliance"
# ————————————————————

### 0) Elevate to root if needed for sysctl & /opt prep
if [[ "$(id -u)" -ne 0 ]]; then
  echo "🔐 Elevating to root for system prep…"
  exec sudo bash "$0" "$@"
fi

echo "✔ Running as root: configuring sysctl & directories"

# 1) Enable low ports & user namespaces for rootless Podman
cat <<EOF >/etc/sysctl.d/conjur.conf
# Allow low port numbers for rootless Podman
net.ipv4.ip_unprivileged_port_start=443
# Increase max user namespaces
user.max_user_namespaces=28633
EOF
sysctl -p /etc/sysctl.d/conjur.conf

# 2) Create the Conjur mount points under /opt and hand them to 'thomas'
CONJUR_USER="thomas"
for d in security config backups seeds logs; do
  mkdir -p /opt/cyberark/conjur/"$d"
  chown "$CONJUR_USER":"$CONJUR_USER" /opt/cyberark/conjur/"$d"
done

echo "✔ System‐level prep complete. Dropping to $CONJUR_USER for Podman steps…"

### 3) Switch to the unprivileged user for everything else
exec sudo -u "$CONJUR_USER" bash <<'USER_SCRIPT'
set -euo pipefail
exec </dev/tty

# 4) Locate the latest appliance tarball and derive version
IMAGE_TAR=\$(ls conjur-appliance-*.tar.gz 2>/dev/null | sort -V | tail -n1)
if [[ -z "\$IMAGE_TAR" ]]; then
  echo "❌ No conjur-appliance-*.tar.gz found in \$(pwd)."
  exit 1
fi
VERSION=\${IMAGE_TAR#conjur-appliance-}
VERSION=\${VERSION%.tar.gz}
IMAGE_REF="${IMAGE_PREFIX}:\${VERSION}"
HOSTFQDN=\$(hostname -f)

# 5) Prompt for the Conjur role
read -rp "Conjur role (leader | standby | follower): " ROLE
if [[ ! "\$ROLE" =~ ^(leader|standby|follower)$ ]]; then
  echo "❌ Invalid role; must be leader, standby, or follower."
  exit 1
fi

echo
echo "→ Loading image (\$IMAGE_TAR) into rootless Podman…"
podman load -i "\$IMAGE_TAR"

echo "→ Starting Conjur container (\$ROLE)…"
COMMON_OPTS=(
  --name "conjur-\${ROLE}"
  --hostname "\$HOSTFQDN"
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
if [[ "\$ROLE" =~ ^(leader|standby)$ ]]; then
  COMMON_OPTS+=(--publish 5432:5432 --publish 1999:1999)
fi
if [[ "\$ROLE" == "leader" ]]; then
  COMMON_OPTS+=(--volume /opt/cyberark/conjur/backups:/opt/conjur/backup:z)
fi

podman run "\${COMMON_OPTS[@]}" "\$IMAGE_REF"

echo "→ Generating systemd user unit for \$(whoami)…"
USER_HOME=\$(eval echo "~\$(whoami)")
mkdir -p "\$USER_HOME/.config/systemd/user"
podman generate systemd "conjur-\${ROLE}" \
  --name --container-prefix="" --separator="" \
  > "\$USER_HOME/.config/systemd/user/conjur.service"

echo "→ Enabling the systemd user service & linger…"
systemctl --user daemon-reload
systemctl --user enable conjur.service
loginctl enable-linger "\$(whoami)"

echo
echo "✅ Conjur \${ROLE^} is now running under rootless Podman!"
echo "   Check with: podman ps"
USER_SCRIPT
