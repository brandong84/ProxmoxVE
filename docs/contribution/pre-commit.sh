#!/bin/bash

################################################################################
# ProxmoxVE Contributor Pre-Commit Hook Installer
#
# Installs an optional local git pre-commit hook to help contributors
# validate their changes before committing.
#
# The hook will:
# - Run ShellCheck on ct and install scripts (if available)
# - Validate JSON metadata using jq (if available)
#
# Notes:
# - This hook is OPTIONAL and opt-in
# - It only affects the local repository
# - It does not modify any tracked files
#
# Usage:
#   ./pre-commit.sh
#
# To remove:
#   rm .git/hooks/pre-commit
################################################################################

HOOK=".git/hooks/pre-commit"
cat <<'EOF' > "$HOOK"
#!/usr/bin/env bash
set -e
command -v shellcheck >/dev/null && shellcheck ct/*.sh install/*.sh || true
command -v jq >/dev/null && jq . json/*.json >/dev/null || true
EOF
chmod +x "$HOOK"
echo "[OK] pre-commit hook installed"
