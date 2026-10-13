#!/usr/bin/env bash
# Installs the Forward Terraform provider from its GitHub release into
# Terraform's local plugin directory, for as long as it is not on the
# Terraform Registry. Checks the release's SHA-256 sum before installing.
#
#   scripts/install-forward-provider.sh            # version below
#   VERSION=0.7.1 scripts/install-forward-provider.sh
#   PLUGIN_DIR=/opt/terraform/plugins scripts/install-forward-provider.sh
#
# Linux and macOS, amd64 and arm64. Needs curl, unzip and shasum.
set -euo pipefail

VERSION=${VERSION:-0.7.1}
PLUGIN_DIR=${PLUGIN_DIR:-$HOME/.terraform.d/plugins}

OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m | sed 's/x86_64/amd64/; s/aarch64/arm64/')
case "$OS/$ARCH" in
  linux/amd64 | linux/arm64 | darwin/amd64 | darwin/arm64) ;;
  *) echo "unsupported platform $OS/$ARCH" >&2; exit 1 ;;
esac

URL=https://github.com/forwardnetworks/terraform-provider-forward/releases/download/v$VERSION
ZIP=terraform-provider-forward_${VERSION}_${OS}_${ARCH}.zip
SUMS=terraform-provider-forward_${VERSION}_SHA256SUMS
DIR=$PLUGIN_DIR/registry.terraform.io/forwardnetworks/forward/$VERSION/${OS}_${ARCH}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"
curl -fsSLO "$URL/$ZIP"
curl -fsSLO "$URL/$SUMS"
grep " $ZIP\$" "$SUMS" | shasum -a 256 -c -
mkdir -p "$DIR"
unzip -oq "$ZIP" -d "$DIR"
echo "installed forwardnetworks/forward $VERSION in $DIR"
