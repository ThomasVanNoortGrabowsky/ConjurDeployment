#!/usr/bin/env bash
# ConjurImage.sh — dynamically build & load the Conjur appliance from your VMware share

set -euo pipefail
IFS=$'\n\t'

##
## 1) CONFIGURATION — adjust these if your paths differ
##

# The .zip sitting on your VMware shared folder (with the space + underscore in its name)
SHARED_ZIP="/mnt/hgfs/File_Sharing/Conjur Enterprise_13.6_17.474379609528.zip"

# Where the ZIP will unpack inside the share
SHARED_BASE="/mnt/hgfs/File_Sharing"

# After unzipping, the appliance build script lives here:
SHARED_APPLIANCE_DIR="$SHARED_BASE/Conjur Enterprise/Conjur Enterprise Appliance"

# Where we want the finished directory tree to live in your home
HOME_DEPLOY_BASE="$HOME/ConjurDeployment"
HOME_APPLIANCE_DIR="$HOME_DEPLOY_BASE/Conjur Enterprise/Conjur Enterprise Appliance"


##
## 2) UNZIP in the SHARE (so the embedded build script can run)
##
echo "==> 2) Unzipping appliance ZIP into the VMware share..."
mkdir -p "$SHARED_BASE"
pushd "$SHARED_BASE" >/dev/null

if [[ ! -f "$SHARED_ZIP" ]]; then
  echo "Error: ZIP not found at $SHARED_ZIP" >&2
  exit 1
fi

unzip -o "$SHARED_ZIP"
popd >/dev/null


##
## 3) RUN the build script that generates conjur-appliance-*.tar.gz
##
echo "==> 3) Running the appliance-build script in the share..."
if [[ ! -d "$SHARED_APPLIANCE_DIR" ]]; then
  echo "Error: expected folder not found: $SHARED_APPLIANCE_DIR" >&2
  exit 1
fi

pushd "$SHARED_APPLIANCE_DIR" >/dev/null
# find and execute the first executable *tar*.sh script
BUILD_SCRIPT=$(find . -maxdepth 1 -type f -executable -name '*tar*.sh' | head -n1 || true)
if [[ -z "$BUILD_SCRIPT" ]]; then
  echo "Error: no '*tar*.sh' script found in $SHARED_APPLIANCE_DIR" >&2
  exit 1
fi

echo "→ Executing ./$BUILD_SCRIPT"
./"$BUILD_SCRIPT"
popd >/dev/null


##
## 4) COPY the built tree back into your HOME (optional, for persistence)
##
echo "==> 4) Copying built Conjur directory into $HOME_APPLIANCE_DIR..."
mkdir -p "$HOME_DEPLOY_BASE"
# Copy the entire "Conjur Enterprise" folder
cp -a "$SHARED_BASE/Conjur Enterprise" "$HOME_DEPLOY_BASE/"


##
## 5) LOCATE & LOAD the appliance tarball
##
echo "==> 5) Locating conjur-appliance-*.tar.gz..."
TARBALL=$(find "$HOME_APPLIANCE_DIR" -maxdepth 1 -type f -name 'conjur-appliance-*.tar.gz' | sort | tail -n1 || true)
if [[ -z "$TARBALL" ]]; then
  echo "Error: no conjur-appliance-*.tar.gz found in $HOME_APPLIANCE_DIR" >&2
  exit 1
fi

echo "→ Found: $TARBALL"
echo "==> 6) Loading into Docker..."
docker load -i "$TARBALL"


##
## 7) (Optional) start with docker-compose
##
COMPOSE_FILE="./docker-compose.yml"
if [[ -f "$COMPOSE_FILE" ]]; then
  echo "==> 7) Starting Conjur via Docker Compose"
  docker-compose -f "$COMPOSE_FILE" up -d
  echo "→ Done. Conjur should be up in a moment."
else
  echo "==> 7) No docker-compose.yml found; skipping container startup."
fi

echo
echo "✅  All done! The appliance tarball was built from the share, copied to:"
echo "   $HOME_APPLIANCE_DIR"
echo "   and loaded into Docker."
