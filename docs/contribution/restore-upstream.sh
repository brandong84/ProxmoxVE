#!/usr/bin/env bash

################################################################################
# ProxmoxVE Contribution Project - Restore Upstream Script
#
# Reverts fork-based raw.githubusercontent.com URLs back to the official
# community-scripts/ProxmoxVE main branch.
#
# This script should be run BEFORE opening a Pull Request.
#
# It safely restores:
#   - misc/build.func
#   - misc/install.func
#   - Any contributed scripts created during setup_contrib.sh
#
# No files are deleted or overwritten — only URLs are normalized.
#
# Usage:
#   ./restore-upstream.sh
#
# Example workflow:
#   Create project
#     docs/contribution/setup_contrib.sh
#   Develop & test
#     git commit -am "feat(romm): initial implementation"
#   Restore upstream before PR
#     docs/contribution/restore-upstream.sh
#   Verify
#     git diff
#   Push + open PR
#     git push origin feat/romm-ct
################################################################################

set -u
IFS=$'\n\t'

# ─────────────────────────────────────────────
# Logging helpers
# ─────────────────────────────────────────────
msg_info()  { echo -e "\e[34m[INFO]\e[0m $*"; }
msg_ok()    { echo -e "\e[32m[OK]\e[0m $*"; }
msg_warn()  { echo -e "\e[33m[WARN]\e[0m $*"; }
msg_error() { echo -e "\e[31m[ERROR]\e[0m $*" >&2; }
fatal() { msg_error "$1"; exit 1; }

# ─────────────────────────────────────────────
# Preconditions
# ─────────────────────────────────────────────
[[ -d .git ]] || fatal "Run from repository root"

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || fatal "Not a git repository"
cd "$ROOT" || exit 1

msg_info "Repository root: $ROOT"

# ─────────────────────────────────────────────
# URL normalization
# ─────────────────────────────────────────────
UPSTREAM_RAW="https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main"

restore_file() {
  local file="$1"
  [[ -f "$file" ]] || return 0

  if grep -q "raw.githubusercontent.com/.*/ProxmoxVE/" "$file"; then
    sed -i \
      "s|https://raw.githubusercontent.com/.*/ProxmoxVE/[^/]*/|${UPSTREAM_RAW}/|g" \
      "$file"
    msg_ok "Restored upstream URLs in $file"
  fi
}

# ─────────────────────────────────────────────
# Core function files
# ─────────────────────────────────────────────
restore_file "misc/build.func"
restore_file "misc/install.func"

# ─────────────────────────────────────────────
# Contribution directories
# ─────────────────────────────────────────────
SCAN_DIRS=(
  ct
  vm
  tools/pve
  tools/addon
  install
)

for dir in "${SCAN_DIRS[@]}"; do
  [[ -d "$dir" ]] || continue
  while IFS= read -r -d '' file; do
    restore_file "$file"
  done < <(find "$dir" -type f -name "*.sh" -print0)
done

# ─────────────────────────────────────────────
# JSON files (defensive — no sed unless needed)
# ─────────────────────────────────────────────
if [[ -d json ]]; then
  while IFS= read -r -d '' file; do
    restore_file "$file"
  done < <(find json -type f -name "*.json" -print0)
fi

# ─────────────────────────────────────────────
# Final check
# ─────────────────────────────────────────────
if grep -R "raw.githubusercontent.com/.*/ProxmoxVE/" -n \
  ct vm tools install json misc 2>/dev/null | grep -q .; then
  msg_warn "Some fork URLs may still exist — review manually"
else
  msg_ok "All upstream URLs restored successfully"
fi

echo
msg_info "You are now ready to open a Pull Request."
echo

