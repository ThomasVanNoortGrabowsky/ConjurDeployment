#!/usr/bin/env bash
set -euo pipefail
exec </dev/tty    # make sure read prompts come from your terminal

# ↓↓↓ Edit only these if you need to change defaults ↓↓↓
CONJUR_USER="thomas"
IMAGE_PREFIX="registry.tld/conjur-appliance"
# ↑↑↑ end editable section ↑↑↑

# Determine which stage we’re in (default “init”)
STAGE="${STAGE:-init}"

if [[ "$STAGE" != "user" ]]; then
  # ─────────────────────────────────────────────────────────────
  # ROOT PHASE: run as root to configure sysctl & /opt folders
  # ─────────────────────────────────────────────────────────────
  if [[ $EUID -ne 0 ]]; then
    echo "🔐 Elevating to root for system prep…"
    # re-exec under sudo, preserving STAGE=init
    exec sudo env STAGE=init bash "$0"
  fi

  echo "✔ Running as root: configuring sysctl & directories…"

  # Step 2: sysctl tweaks for rootless Podman
  cat >/etc/sysctl.d/conjur.conf <<EOF
net.ipv4.ip_unprivileged_port_start=443
user.max_user_namespaces=28633
EOF
  sysctl -p /etc/sysctl.d/conjur.conf

  # Step 4: create /opt/cyberark/conjur folders and chown to $CONJUR_USER
  for d in security config backups seeds logs; do
    mkdir -p /opt/cyberark/conjur/"$d"
    chown "$CONJUR_USER":"$CONJUR_USER" /opt/cyberark/conjur/"$d"
  done

  echo "✔ System‐level prep done. Dropping to $CONJUR_USER for Podman steps…"

  # re-exec under the unprivileged user with STAGE=user
  exec sudo -u "$CONJUR_USER" env STAGE=user bash "$0"
fi

# ─────────────────────────────────────────────────────────────
# USER PHASE: now running as $CONJUR_USER, STAGE=user
# ─────────────────────────────────────────────────────────────

echo "👤 Running as user: $(whoami) — starting rootless Podman deployment…"

# Step 6: find the appliance tarball and derive version
IMAGE_TAR=$(ls conjur-appliance-*.tar.gz 2>/dev/null | sort -V | tail -n1)
if [[ -z "$IMAGE_TAR" ]]; then
  echo "❌ No conjur-appliance-*.tar.gz found in $(pwd). Exiting." >&2
  exit 1
fi
VERSION="${IMAGE_TAR#conjur-appliance-}"
VERSION="${VERSION%.tar.gz}"
IMAGE_REF="${IMAGE_PREFIX}:${VERSION}"
HOSTFQDN=$(hostname -f)

# Step 5: ask for your role
read -rp "Conjur role (leader | standby | follower): " ROLE
if [[ ! "$ROLE" =~ ^(leader|standby|follower)$ ]]; then
  echo "❌ Invalid role. Must be leader, standby, or follower." >&2
  exit 1
fi

echo
echo "→ Loading Conjur image ($IMAGE_TAR) into rootless Podman…"
podman load -i "$IMAGE_TAR"

echo "→ Starting Conjur container as '$ROLE'…"
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

podman run "${COMMON_OPTS[@]}" "$IMAGE_REF"

echo "→ Generating systemd user service for Podman auto-start…"
USER_HOME=$(eval echo "~$(whoami)")
mkdir -p "$USER_HOME/.config/systemd/user"
podman generate systemd "conjur-${ROLE}" \
  --name --container-prefix="" --separator="" \
  > "$USER_HOME/.config/systemd/user/conjur.service"

echo "→ Enabling the systemd user service and linger…"
systemctl --user daemon-reload
systemctl --user enable conjur.service
loginctl enable-linger "$(whoami)"

echo
echo "✅ Conjur ${ROLE^} is now running under rootless Podman!"
echo "   Verify with: podman ps"
