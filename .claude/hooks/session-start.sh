#!/bin/bash
# Installs PowerShell so the repo's .ps1 tooling can be run and tested inside a
# Claude Code on the web session. Those containers are Linux and ephemeral --
# without this, pwsh is absent and every script here can only be read, not run.
#
# Idempotent: exits immediately when pwsh is already present.
set -euo pipefail

# Local machines have their own PowerShell; only the remote container needs this.
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
    exit 0
fi

if command -v pwsh >/dev/null 2>&1; then
    echo "pwsh already installed: $(pwsh --version)"
    exit 0
fi

if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
elif command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
else
    echo "Cannot install PowerShell: not root and no sudo available." >&2
    exit 0   # a missing pwsh is a degraded session, not a broken one
fi

# Ubuntu ships no PowerShell package; Microsoft's own repo does. The release is
# read from the running image rather than pinned, so this survives an upgrade.
. /etc/os-release
DEB="/tmp/packages-microsoft-prod-${VERSION_ID}.deb"

echo "Installing PowerShell for Ubuntu ${VERSION_ID}..."
curl -fsSL -o "$DEB" \
    "https://packages.microsoft.com/config/ubuntu/${VERSION_ID}/packages-microsoft-prod.deb"
$SUDO dpkg -i "$DEB" >/dev/null
rm -f "$DEB"

# Refresh only Microsoft's list. A full apt-get update pulls every other
# configured repo and is the slow, failure-prone part of this script.
$SUDO apt-get update \
    -o Dir::Etc::sourcelist="sources.list.d/microsoft-prod.list" \
    -o Dir::Etc::sourceparts="-" \
    -o APT::Get::List-Cleanup="0" >/dev/null

$SUDO DEBIAN_FRONTEND=noninteractive apt-get install -y powershell >/dev/null

echo "Installed $(pwsh --version)"
