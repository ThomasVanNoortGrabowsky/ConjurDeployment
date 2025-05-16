#!/usr/bin/env bash
# deploy-conjur.sh  —  find, load, and start Conjur appliance

set -euo pipefail
IFS=$'\n\t'

# 1) Where your .tar.gz lives (with spaces handled)
DEPLOY_DIR="$HOME/ConjurDeployment/Conjur Enterprise/Conjur Enterprise Alliance"

# 2) Path to your Docker Compose file (adjust if needed)
COMPOSE_FILE="./docker-compose.yml"

# 3) Ensure workspace
echo "==> Checking deployment directory"
if [[ ! -d "$DEPLOY_DIR" ]]; then
  echo "Error: directory not found: $DEPLOY_DIR" >&2
  exit 1
fi

# 4) Find the newest appliance tarball
echo "==> Locating conjur-appliance-*.tar.gz in:"
echo "    $DEPLOY_DIR"
TARBALL=$(find "$DEPLOY_DIR" -maxdepth 1 -type f -name 'conjur-appliance-*.tar.gz' \
           | sort \
           | tail -n1 || true)

if [[ -z "$TARBALL" ]]; then
  echo "Error: no conjur-appliance-*.tar.gz found in $DEPLOY_DIR" >&2
  exit 1
fi
echo "==> Using appliance tarball: $TARBALL"

# 5) Load the appliance into Docker
if [[ -x "./_load_conjur_tarfile.sh" ]]; then
  echo "==> Running local loader script: ./_load_conjur_tarfile.sh \"$TARBALL\""
  exec ./_load_conjur_tarfile.sh "$TARBALL"
else
  echo "==> No loader script found; falling back to 'docker load'"
  docker load -i "$TARBALL"
fi

# 6) Bring up Conjur via Docker Compose
echo "==> Starting Conjur services with Docker Compose"
if [[ ! -f "$COMPOSE_FILE" ]]; then
  echo "Error: Compose file not found at $COMPOSE_FILE" >&2
  exit 1
fi
docker-compose -f "$COMPOSE_FILE" up -d

# 7) Wait for Conjur API to be healthy
echo -n "==> Waiting for Conjur to become healthy"
RETRIES=30
until docker-compose -f "$COMPOSE_FILE" exec -T conjur-api conjur health 2>/dev/null | grep -q 'OK'; do
  ((RETRIES--)) || { echo; echo "Error: Conjur API failed to become healthy" >&2; exit 1; }
  echo -n "."
  sleep 5
done
echo " OK"

# 8) Print connection details
CONJUR_URL="https://$(docker-compose -f "$COMPOSE_FILE" port conjur-api 443 | awk -F: '{print $1}')"
echo
echo "Conjur is up and running!"
echo "  URL:  $CONJUR_URL"
echo "  Admin user:   admin"
echo "  Admin password: $(docker-compose -f "$COMPOSE_FILE" exec -T conjur-api conjur admin password show)"
echo
echo "You can now log in with:"
echo "  conjur login -u admin -p <password> -a appliance"
echo
