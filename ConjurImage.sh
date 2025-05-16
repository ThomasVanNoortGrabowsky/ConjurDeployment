#!/usr/bin/env bash
# ConjurImage.sh — dynamically build & load the Conjur appliance from your VMware share

set -euo pipefail
IFS=$'\n\t'

##
## 1) CONFIGURATION
##

# VMware share root
SHARED_BASE="/mnt/hgfs/File_Sharing"

# After unzipping, the build script lives here:
SHARED_APPLIANCE_DIR="$SHARED_BASE/Conjur Enterprise/Conjur Enterprise Appliance"

# Where we want the final tree in your home
HOME_DEPLOY_BASE="$HOME/ConjurDeployment"
HOME_APPLIANCE_DIR="$HOME_DEPLOY_BASE/Conjur Enterprise/Conjur Enterprise Appliance"

##
## 2) Find the ZIP under /mnt/hgfs/File_Sharing
##
echo "==> Locating conjur*.zip in $SHARED_BASE"
ZIP=$(find "$SHARED_BASE" -maxdepth 1 -type f -iname 'conjur*.zip' | head -n1 || true)
if [[ -z "$ZIP" ]]; then
  echo "Error: no conjur*.zip found in $SHARED_BASE" >&2
  exit 1
fi
echo "→ Found ZIP: $ZIP"

##
## 3) Unzip in the VMware share
##
echo "==> Unzipping $ZIP into $SHARED_BASE"
pushd "$SHARED_BASE" >/dev/null
unzip -o "$ZIP"
popd >/dev/null

##
## 4) Run the build script to generate conjur-appliance-*.tar.gz
##
echo "==> Running build script in $SHARED_APPLIANCE_DIR"
if [[ ! -d "$SHARED_APPLIANCE_DIR" ]]; then
  echo "Error: expected folder not found: $SHARED_APPLIANCE_DIR" >&2
  exit 1
fi

pushd "$SHARED_APPLIANCE_DIR" >/dev/null
BUILD_SCRIPT=$(find . -maxdepth 1 -type f -executable -name '*tar*.sh' | head -n1 || true)
if [[ -z "$BUILD_SCRIPT" ]]; then
  echo "Error: no '*tar*.sh' script found in $SHARED_APPLIANCE_DIR" >&2
  exit 1
fi
echo "→ Executing ./$BUILD_SCRIPT"
./"$BUILD_SCRIPT"
popd >/dev/null

##
## 5) Copy the built directory into your home
##
echo "==> Copying built Conjur directory to $HOME_DEPLOY_BASE"
mkdir -p "$HOME_DEPLOY_BASE"
cp -a "$SHARED_BASE/Conjur Enterprise" "$HOME_DEPLOY_BASE/"

##
## 6) Locate & load the resulting tarball
##
echo "==> Locating conjur-appliance-*.tar.gz in $HOME_APPLIANCE_DIR"
TARBALL=$(find "$HOME_APPLIANCE_DIR" -maxdepth 1 -type f -name 'conjur-appliance-*.tar.gz' \
          | sort | tail -n1 || true)
if [[ -z "$TARBALL" ]]; then
  echo "Error: no conjur-appliance-*.tar.gz found in $HOME_APPLIANCE_DIR" >&2
  exit 1
fi
echo "→ Found tarball: $TARBALL"

echo "==> Loading $TARBALL into Docker"
docker load -i "$TARBALL"

##
## 7) (Optional) Start with docker-compose
##
COMPOSE_FILE="./docker-compose.yml"
if [[ -f "$COMPOSE_FILE" ]]; then
  echo "==> Starting Conjur via Docker Compose"
  docker-compose -f "$COMPOSE_FILE" up -d
  echo "→ Conjur should be up shortly."
else
  echo "==> No docker-compose.yml found; skipping startup."
fi

echo
echo "✅  Done! Appliance built from the share, copied to:"
echo "    $HOME_APPLIANCE_DIR"
echo "    and loaded into Docker."
