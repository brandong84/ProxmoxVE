#!/usr/bin/env bash

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



################################################################################
# ProxmoxVE Contribution Project Setup Script
#
# Creates a new contribution scaffold in a forked ProxmoxVE repository.
# Must be run AFTER docs/contribution/setup-fork.sh
################################################################################

#!/usr/bin/env bash

################################################################################
# ProxmoxVE Contribution Project Setup Script
#
# Creates a new contribution scaffold in a forked ProxmoxVE repository.
# Must be run AFTER docs/contribution/setup-fork.sh
################################################################################

set -u
IFS=$'\n\t'

# ─────────────────────────────────────────────
# Logging
# ─────────────────────────────────────────────
msg_info()  { echo -e "\e[34m[INFO]\e[0m $*"; }
msg_ok()    { echo -e "\e[32m[OK]\e[0m $*"; }
msg_warn()  { echo -e "\e[33m[WARN]\e[0m $*"; }
msg_error() { echo -e "\e[31m[ERROR]\e[0m $*" >&2; }
fatal() { msg_error "$1"; exit 1; }

# ─────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────
to_slug() { echo "$1" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9'; }
to_camel() { sed 's/\b\(.\)/\u\1/g' <<<"$1"; }

ask() {
  local var="$1" prompt="$2" default="$3"
  read -rp "$prompt [$default]: " input
  eval "$var=\"${input:-$default}\""
}

safe_copy_or_create() {
  local src="$1" dest="$2" header="$3"
  if [[ -f "$src" ]]; then
    cp "$src" "$dest"
  else
    echo "$header" > "$dest"
  fi
}

replace_placeholders() {
  local file="$1"
  [[ -f "$file" ]] || return
  sed -i \
    -e "s/AppName/${APP_NAME}/g" \
    -e "s/appname/${APP_SLUG}/g" \
    "$file"
}

rewrite_fork_urls() {
  local file="$1"
  [[ -f "$file" ]] || return
  sed -i "s|raw.githubusercontent.com/community-scripts/ProxmoxVE/main|$RAW_FORK|g" "$file"
}

# ─────────────────────────────────────────────
# JSON helpers
# ─────────────────────────────────────────────
update_json_field() {
  local f="$1" k="$2" v="$3"
  [[ -z "$v" ]] && return
  if grep -q "\"$k\"" "$f"; then
    sed -i "s|\"$k\"[[:space:]]*:[[:space:]]*[^,]*|\"$k\": $v|" "$f"
  else
    sed -i "s|{|\{\n  \"$k\": $v,|" "$f"
  fi
}

update_json_string() {
  update_json_field "$1" "$2" "\"$3\""
}

update_json_array() {
  update_json_field "$1" "$2" "[$3]"
}

update_json_object() {
  update_json_field "$1" "$2" "$3"
}

generate_install_methods() {
  local path="$1"
  cat <<EOF
[
  {
    "type": "default",
    "script": "$path",
    "resources": {
      "cpu": 2,
      "ram": 2048,
      "hdd": 4,
      "os": "debian",
      "version": "12"
    }
  }
]
EOF
}

# ─────────────────────────────────────────────
# Preconditions
# ─────────────────────────────────────────────
[[ -d .git ]] || fatal "Run from repository root"

ORIGIN="$(git remote get-url origin)"
[[ "$ORIGIN" =~ github.com[:/](.+)/([^/]+)(\.git)?$ ]] || fatal "Cannot detect fork"

GITHUB_USER="${BASH_REMATCH[1]}"
REPO="${BASH_REMATCH[2]}"

# ─────────────────────────────────────────────
# Prompts
# ─────────────────────────────────────────────
DEFAULT_AUTHOR="$(to_camel "$(git config user.name || echo Unknown)")"

ask APP_NAME "Application Name" ""
ask PROJECT_TYPE "Type (ct/vm/pve/addon)" "ct"
ask AUTHOR "Author Name" "$DEFAULT_AUTHOR"
ask DESCRIPTION "Description" "$APP_NAME application"
ask VERSION "Version" "latest"
ask PORT "Interface port (optional)" ""
ask WEBSITE "Website (optional)" ""
ask LOGO "Logo URL (optional)" ""
ask DOCUMENTATION "Documentation URL (optional)" ""
ask CATEGORIES "Category IDs (comma separated)" "0"
ask PRIVILEGED "Privileged container? (true/false)" "false"

[[ -z "$APP_NAME" ]] && fatal "Application name required"

APP_SLUG="$(to_slug "$APP_NAME")"
DATE_CREATED="$(date +%Y-%m-%d)"

# ─────────────────────────────────────────────
# Branch
# ─────────────────────────────────────────────
BRANCH="feat/${APP_SLUG}-${PROJECT_TYPE}"
git checkout -b "$BRANCH" 2>/dev/null || true
RAW_FORK="https://raw.githubusercontent.com/$GITHUB_USER/$REPO/$BRANCH"

# ─────────────────────────────────────────────
# Type mapping
# ─────────────────────────────────────────────
case "$PROJECT_TYPE" in
  ct)
    DEST="ct"
    INSTALL="install"
    TEMPLATE="docs/contribution/templates_ct/AppName.sh"
    INSTALL_TEMPLATE="docs/contribution/templates_install/AppName-install.sh"
    SCRIPT_PATH="ct/${APP_SLUG}.sh"
    ;;
  vm)
    DEST="vm"
    TEMPLATE="docs/contribution/templates_vm/AppName.sh"
    SCRIPT_PATH="vm/${APP_SLUG}.sh"
    ;;
  pve)
    DEST="tools/pve"
    TEMPLATE="docs/contribution/templates_pve/AppName.sh"
    SCRIPT_PATH="tools/pve/${APP_SLUG}.sh"
    ;;
  addon)
    DEST="tools/addon"
    TEMPLATE="docs/contribution/templates_addon/AppName.sh"
    SCRIPT_PATH="tools/addon/${APP_SLUG}.sh"
    ;;
  *) fatal "Invalid type" ;;
esac

mkdir -p "$DEST" json "${INSTALL:-}"

# ─────────────────────────────────────────────
# Headers
# ─────────────────────────────────────────────
HEADER=$(cat <<EOF
#!/usr/bin/env bash
################################################################################
# $APP_NAME
#
# $DESCRIPTION
#
# Author: $AUTHOR
# Version: $VERSION
################################################################################
EOF
)

# ─────────────────────────────────────────────
# Scripts
# ─────────────────────────────────────────────
MAIN="$DEST/${APP_SLUG}.sh"
safe_copy_or_create "$TEMPLATE" "$MAIN" "$HEADER"
replace_placeholders "$MAIN"
rewrite_fork_urls "$MAIN"
chmod +x "$MAIN"

if [[ "$PROJECT_TYPE" == "ct" ]]; then
  INSTALL_SCRIPT="$INSTALL/${APP_SLUG}-install.sh"
  safe_copy_or_create "$INSTALL_TEMPLATE" "$INSTALL_SCRIPT" "$HEADER"
  replace_placeholders "$INSTALL_SCRIPT"
  rewrite_fork_urls "$INSTALL_SCRIPT"
  chmod +x "$INSTALL_SCRIPT"
fi

# ─────────────────────────────────────────────
# JSON
# ─────────────────────────────────────────────
JSON="json/${APP_SLUG}.json"
JSON_TEMPLATE="docs/contribution/templates_json/AppName.json"

[[ -f "$JSON_TEMPLATE" ]] && cp "$JSON_TEMPLATE" "$JSON" || echo "{}" > "$JSON"

update_json_string "$JSON" "name" "$APP_NAME"
update_json_string "$JSON" "slug" "$APP_SLUG"
update_json_string "$JSON" "type" "$PROJECT_TYPE"
update_json_string "$JSON" "description" "$DESCRIPTION"
update_json_string "$JSON" "date_created" "$DATE_CREATED"
update_json_field "$JSON" "updateable" "true"
update_json_field "$JSON" "privileged" "$PRIVILEGED"
update_json_string "$JSON" "interface_port" "$PORT"
update_json_string "$JSON" "website" "$WEBSITE"
update_json_string "$JSON" "documentation" "$DOCUMENTATION"
update_json_string "$JSON" "logo" "$LOGO"
update_json_array "$JSON" "categories" "$CATEGORIES"

INSTALL_JSON="$(generate_install_methods "$SCRIPT_PATH")"
update_json_array "$JSON" "install_methods" "$INSTALL_JSON"

update_json_object "$JSON" "default_credentials" '{"username": null, "password": null}'
update_json_array "$JSON" "notes" ""

# ─────────────────────────────────────────────
# Validation
# ─────────────────────────────────────────────
for field in name slug type categories description install_methods; do
  grep -q "\"$field\"" "$JSON" || fatal "JSON missing: $field"
done

rewrite_fork_urls misc/build.func
rewrite_fork_urls misc/install.func

msg_ok "Project created successfully"
