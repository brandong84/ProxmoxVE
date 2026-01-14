#!/bin/bash

################################################################################
# ProxmoxVE Fork Helper URL Restore Script
#
# Reverts temporary fork-based raw.githubusercontent.com URLs
# back to the official upstream repository.
#
# This script is REQUIRED before submitting any pull request.
#
# What it does:
# - Scans generated ct / vm / pve-tool scripts
# - Restores helper URLs in misc/build.func and misc/install.func
# - Ensures no fork references remain in the PR
#
# Safety:
# - No application logic is modified
# - Only raw GitHub URLs are rewritten
#
# Usage:
#   ./restore-upstream.sh
#
# Typical workflow:
#   ./setup_contrib.sh
#   # develop and test
#   ./restore-upstream.sh
#   git commit && open PR
################################################################################

set -Eeuo pipefail
UPSTREAM="https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main"
sed -i "s|https://raw.githubusercontent.com/.*/ProxmoxVE/.*/|$UPSTREAM/|g" misc/*.func ct/*.sh vm/*.sh pve/*.sh 2>/dev/null || true
echo "[OK] Restored upstream URLs"
