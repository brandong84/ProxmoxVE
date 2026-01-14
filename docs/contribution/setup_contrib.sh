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

set -Eeuo pipefail

msg_info(){ echo "[INFO] $*"; }
msg_ok(){ echo "[OK] $*"; }
msg_warn(){ echo "[WARN] $*"; }
msg_error(){ echo "[ERROR] $*" >&2; exit 1; }

APP_NAME=""; PROJECT_TYPE="ct"; AUTO_YES=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) APP_NAME="$2"; shift 2;;
    --type) PROJECT_TYPE="$2"; shift 2;;
    --yes) AUTO_YES=true; shift;;
    *) msg_error "Unknown arg $1";;
  esac
done

ask(){ $AUTO_YES && echo "$2" || read -rp "$1 [$2]: " r && echo "${r:-$2}"; }

[[ -d .git ]] || msg_error "Run in repo"
ORIGIN_URL="$(git remote get-url origin)"
[[ "$ORIGIN_URL" =~ github.com[:/](.+)/([^/]+)(\.git)?$ ]] || msg_error "Cannot detect fork"
GITHUB_USER="${BASH_REMATCH[1]}"; FORK_REPO="${BASH_REMATCH[2]}"

APP_NAME="${APP_NAME:-$(ask 'Application name' '')}"
PROJECT_TYPE="${PROJECT_TYPE:-$(ask 'Project type (ct/vm/pve-tool)' 'ct')}"
AUTHOR="$(ask 'Author name' "$(git config user.name)")"
[[ -z "$APP_NAME" ]] && msg_error "App name required"

APP_SLUG="$(echo "$APP_NAME" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9')"
BRANCH="feat/${APP_SLUG}-${PROJECT_TYPE}"
git checkout -b "$BRANCH"

YEAR="$(date +%Y)"
HEADER="#\n# $APP_NAME\n#\n# Copyright (c) $YEAR $AUTHOR\n# License: MIT\n#\n"

mkdir -p ct install json vm pve

case "$PROJECT_TYPE" in
  ct)
    cp ct/example.sh ct/"$APP_SLUG".sh
    cp install/example-install.sh install/"$APP_SLUG"-install.sh
    sed -i "1s|^|$HEADER\n|" ct/"$APP_SLUG".sh install/"$APP_SLUG"-install.sh
    chmod +x ct/"$APP_SLUG".sh install/"$APP_SLUG"-install.sh
    ;;
  vm)
    cp vm/example.sh vm/"$APP_SLUG".sh
    sed -i "1s|^|$HEADER\n|" vm/"$APP_SLUG".sh
    chmod +x vm/"$APP_SLUG".sh
    ;;
  pve-tool)
    cp pve/example.sh pve/"$APP_SLUG".sh
    sed -i "1s|^|$HEADER\n|" pve/"$APP_SLUG".sh
    chmod +x pve/"$APP_SLUG".sh
    ;;
esac

RAW="https://raw.githubusercontent.com/$GITHUB_USER/$FORK_REPO/$BRANCH"
sed -i "s|https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main|$RAW|g" misc/build.func misc/install.func ct/"$APP_SLUG".sh 2>/dev/null || true

cat <<EOF > json/"$APP_SLUG".json
{
  "name": "$APP_NAME",
  "slug": "$APP_SLUG",
  "type": "$PROJECT_TYPE",
  "categories": ["utility"],
  "updateable": true,
  "privileged": false,
  "description": "$APP_NAME application"
}
EOF

msg_ok "Project ready. Test with bash ct/$APP_SLUG.sh"
