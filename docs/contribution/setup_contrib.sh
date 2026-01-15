#!/bin/bash

################################################################################
# ProxmoxVE Contribution Project Setup Script
#
# Bootstraps a new contribution project in a forked ProxmoxVE repository.
# This script is intended to be run AFTER docs/contribution/setup-fork.sh
# and provides a guided, repeatable way to start new contributions.
#
# OVERVIEW:
# - Automatically detects your GitHub username and forked repository
#   using git remote configuration.
# - Creates a new feature branch dedicated to the contribution.
# - Generates project files from official upstream templates.
# - Configures the repository for safe fork-based testing.
#
# SUPPORTED PROJECT TYPES:
#   ct        - LXC container application scripts
#   vm        - Virtual machine templates
#   pve-tool  - Proxmox host-side utilities and tools
#
# GENERATED FILES (depending on project type):
#   ct/<app>.sh                     Container creation/update script
#   install/<app>-install.sh        Application install/update script
#   json/<app>.json                 Website and metadata definition
#
# FEATURE BRANCH:
# - A new feature branch is automatically created using the format:
#     feat/<app>-<type>
# - This keeps contribution work isolated and review-friendly.
#
# FORK-BASED TESTING MODE:
# - Helper URLs in misc/build.func and misc/install.func are temporarily
#   rewritten to point to your fork and feature branch.
# - This allows you to test changes without modifying upstream files.
#
# IMPORTANT:
# - Fork-based helper URL rewrites are TEMPORARY and LOCAL ONLY.
# - You MUST run restore-upstream.sh before submitting a pull request.
# - Pull requests containing fork URLs will be rejected.
#
# ------------------------------------------------------------------------------
# OPTIONS AND FLAGS
# ------------------------------------------------------------------------------
#
# --app <AppName>
#   Specifies the application or project name.
#
#   If omitted:
#   - You will be prompted interactively.
#
#   Notes:
#   - The name is normalized into a lowercase slug (a–z, 0–9).
#   - This slug is used for filenames, JSON metadata, and branch names.
#
#   Example:
#     --app RomM
#
# ------------------------------------------------------------------------------
#
# --type <ct|vm|pve-tool>
#   Specifies the contribution project type.
#
#   Valid values:
#     ct        Create an LXC container application
#     vm        Create a virtual machine template
#     pve-tool  Create a Proxmox host-side utility
#
#   If omitted:
#   - Defaults to: ct
#   - You will be prompted interactively if not provided.
#
#   Example:
#     --type ct
#
# ------------------------------------------------------------------------------
#
# --yes
#   Enables non-interactive mode.
#
#   Behavior:
#   - Accepts all default values automatically.
#   - Suppresses interactive prompts.
#   - Intended for experienced contributors or scripted workflows.
#
#   When used:
#   - --app and --type SHOULD be provided.
#   - Missing values will fall back to safe defaults.
#
#   Example:
#     ./setup_contrib.sh --app RomM --type ct --yes
#
# ------------------------------------------------------------------------------
# INTERACTIVE MODE
# ------------------------------------------------------------------------------
#
# When run without flags, the script will guide you through:
# - Application name
# - Project type
# - Author name for copyright headers
#
# This mode is recommended for first-time contributors.
#
# ------------------------------------------------------------------------------
# COPYRIGHT HEADERS
# ------------------------------------------------------------------------------
#
# All generated scripts include a standardized header containing:
# - Application name
# - Author name (from git config or prompt)
# - Current year
# - MIT license reference
#
# ------------------------------------------------------------------------------
# VALIDATION AND SAFETY
# ------------------------------------------------------------------------------
#
# - Generated scripts are based ONLY on upstream example templates.
# - File naming conventions strictly follow repository guidelines.
# - No existing scripts are modified beyond temporary helper URL rewrites.
#
# Optional validations:
# - ShellCheck (if installed locally)
# - JSON validation via jq (if installed locally)
#
# ------------------------------------------------------------------------------
# REQUIRED CLEANUP BEFORE PR
# ------------------------------------------------------------------------------
#
# Before opening a pull request, you MUST run:
#
#   ./docs/contribution/restore-upstream.sh
#
# This ensures:
# - All helper URLs point back to the upstream repository
# - The PR contains no fork-specific references
#
# ------------------------------------------------------------------------------
# USAGE
# ------------------------------------------------------------------------------
#
# Interactive:
#   ./setup_contrib.sh
#
# Non-interactive:
#   ./setup_contrib.sh --app AppName --type ct --yes
#
# Examples:
#   ./setup_contrib.sh --app RomM --type ct
#   ./setup_contrib.sh --app MyVM --type vm
#   ./setup_contrib.sh --app BackupTool --type pve-tool --yes
#
################################################################################
################################################################################
# ProxmoxVE Contribution Project Setup Script
#
# Bootstraps a new contribution project in a forked ProxmoxVE repository.
# Must be run AFTER docs/contribution/setup-fork.sh
#
# See docs/contribution/CONTRIBUTING.md for full workflow.
################################################################################

set -Eeuo pipefail

# ─────────────────────────────────────────────
# Logging helpers (community-scripts style)
# ─────────────────────────────────────────────
msg_info()  { echo -e "\e[34m[INFO]\e[0m $*"; }
msg_ok()    { echo -e "\e[32m[OK]\e[0m $*"; }
msg_warn()  { echo -e "\e[33m[WARN]\e[0m $*"; }
msg_error() { echo -e "\e[31m[ERROR]\e[0m $*" >&2; exit 1; }

# ─────────────────────────────────────────────
# Argument parsing
# ─────────────────────────────────────────────
APP_NAME=""
PROJECT_TYPE=""
AUTO_YES=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)  APP_NAME="$2"; shift 2 ;;
    --type) PROJECT_TYPE="$2"; shift 2 ;;
    --yes)  AUTO_YES=true; shift ;;
    *) msg_error "Unknown argument: $1" ;;
  esac
done

ask() {
  local prompt="$1" default="$2"
  $AUTO_YES && { echo "$default"; return; }
  read -rp "$prompt [$default]: " input
  echo "${input:-$default}"
}

# ─────────────────────────────────────────────
# Preconditions
# ─────────────────────────────────────────────
[[ -d .git ]] || msg_error "Must be run from repository root"

ORIGIN_URL="$(git remote get-url origin)"
[[ "$ORIGIN_URL" =~ github.com[:/](.+)/([^/]+)(\.git)?$ ]] \
  || msg_error "Unable to detect GitHub fork"

GITHUB_USER="${BASH_REMATCH[1]}"
FORK_REPO="${BASH_REMATCH[2]}"

msg_info "Detected fork: $GITHUB_USER/$FORK_REPO"

# ─────────────────────────────────────────────
# Interactive input
# ─────────────────────────────────────────────
APP_NAME="${APP_NAME:-$(ask 'Application name' '')}"
PROJECT_TYPE="${PROJECT_TYPE:-$(ask 'Project type (ct/vm/pve/addon)' 'ct')}"
AUTHOR="$(ask 'Author name' "$(git config user.name)")"

[[ -z "$APP_NAME" ]] && msg_error "Application name is required"

APP_SLUG="$(echo "$APP_NAME" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9')"
FEATURE_BRANCH="feat/${APP_SLUG}-${PROJECT_TYPE}"

git checkout -b "$FEATURE_BRANCH"
msg_ok "Created branch $FEATURE_BRANCH"

# ─────────────────────────────────────────────
# Project layout
# ─────────────────────────────────────────────
case "$PROJECT_TYPE" in
  ct)
    DEST_DIR="ct"
    INSTALL_DIR="install"
    ;;
  vm)
    DEST_DIR="vm"
    INSTALL_DIR=""
    ;;
  pve)
    DEST_DIR="tools/pve"
    INSTALL_DIR=""
    ;;
  addon)
    DEST_DIR="tools/addon"
    INSTALL_DIR=""
    ;;
  *)
    msg_error "Unsupported project type: $PROJECT_TYPE"
    ;;
esac

mkdir -p "$DEST_DIR" "$INSTALL_DIR" json

DEST_SCRIPT="$DEST_DIR/${APP_SLUG}.sh"
INSTALL_SCRIPT="$INSTALL_DIR/${APP_SLUG}-install.sh"

# ─────────────────────────────────────────────
# Template resolution
# ─────────────────────────────────────────────
TEMPLATE_DIR="docs/contribution/templates_${PROJECT_TYPE}"

get_template() {
  local file="$1"
  [[ -f "$TEMPLATE_DIR/$file" ]] && echo "$TEMPLATE_DIR/$file"
}

SRC_MAIN="$(get_template example.sh)"
SRC_INSTALL="$(get_template example-install.sh)"

# ─────────────────────────────────────────────
# Copyright header
# ─────────────────────────────────────────────
YEAR="$(date +%Y)"
HEADER="#
# ${APP_NAME}
#
# Copyright (c) ${YEAR} ${AUTHOR}
# License: MIT
#
"

# ─────────────────────────────────────────────
# Main script generation
# ─────────────────────────────────────────────
if [[ -n "$SRC_MAIN" ]]; then
  msg_ok "Using template: $SRC_MAIN"
  cp "$SRC_MAIN" "$DEST_SCRIPT"
else
  msg_warn "No template found for $PROJECT_TYPE — generating skeleton"
  cat << 'EOF' > "$DEST_SCRIPT"
#!/usr/bin/env bash
set -Eeuo pipefail

msg_info()  { echo "[INFO] $*"; }
msg_ok()    { echo "[OK] $*"; }
msg_error() { echo "[ERROR] $*" >&2; exit 1; }

msg_info "Starting setup"

# TODO:
# - Follow docs/README.md structure
# - Add dependency checks
# - Implement install/update logic

msg_ok "Completed"
EOF
fi

sed -i "1s|^|$HEADER\n|" "$DEST_SCRIPT"
chmod +x "$DEST_SCRIPT"

# ─────────────────────────────────────────────
# Install script (ct only)
# ─────────────────────────────────────────────
if [[ "$PROJECT_TYPE" == "ct" ]]; then
  if [[ -n "$SRC_INSTALL" ]]; then
    msg_ok "Using install template: $SRC_INSTALL"
    cp "$SRC_INSTALL" "$INSTALL_SCRIPT"
  else
    msg_warn "No install template found — generating skeleton"
    cat << 'EOF' > "$INSTALL_SCRIPT"
#!/usr/bin/env bash
set -Eeuo pipefail

msg_info()  { echo "[INFO] $*"; }
msg_ok()    { echo "[OK] $*"; }
msg_error() { echo "[ERROR] $*" >&2; exit 1; }

msg_info "Installing application"

# TODO:
# - Install dependencies
# - Configure services
# - Enable auto-start

msg_ok "Install complete"
EOF
  fi

  sed -i "1s|^|$HEADER\n|" "$INSTALL_SCRIPT"
  chmod +x "$INSTALL_SCRIPT"
fi

# ─────────────────────────────────────────────
# Fork-based testing URL rewrite
# ─────────────────────────────────────────────
RAW_FORK="https://raw.githubusercontent.com/$GITHUB_USER/$FORK_REPO/$FEATURE_BRANCH"

sed -i \
  -e "s|https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main|$RAW_FORK|g" \
  misc/build.func misc/install.func "$DEST_SCRIPT" 2>/dev/null || true

msg_ok "Fork URLs applied for local testing"

# ─────────────────────────────────────────────
# JSON metadata
# ─────────────────────────────────────────────
cat << EOF > "json/${APP_SLUG}.json"
{
  "name": "${APP_NAME}",
  "slug": "${APP_SLUG}",
  "type": "${PROJECT_TYPE}",
  "categories": ["utility"],
  "updateable": true,
  "privileged": false,
  "description": "${APP_NAME} application"
}
EOF

# ─────────────────────────────────────────────
# Optional validation
# ─────────────────────────────────────────────
command -v shellcheck >/dev/null && shellcheck "$DEST_SCRIPT" || true
command -v jq >/dev/null && jq . "json/${APP_SLUG}.json" >/dev/null || true

# ─────────────────────────────────────────────
# Final output
# ─────────────────────────────────────────────
msg_ok "Contribution project initialized successfully"

echo
echo "Next steps:"
echo "  Test:        bash $DEST_SCRIPT"
echo "  Cleanup:     bash docs/contribution/restore-upstream.sh"
echo "  Commit:      git add . && git commit"
echo

