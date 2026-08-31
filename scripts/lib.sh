#!/usr/bin/env bash
# Shared helpers + config loader. Sourced by every other script.
set -euo pipefail

# --- resolve paths & load config ---------------------------------------------
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$LIB_DIR")"
CONFIG_FILE="${CONFIG_FILE:-$ROOT_DIR/config/cluster.env}"

[[ -f "$CONFIG_FILE" ]] || { echo "config not found: $CONFIG_FILE" >&2; exit 1; }
# shellcheck disable=SC1090
source "$CONFIG_FILE"

# --- pretty logging -----------------------------------------------------------
c_grn='\033[0;32m'; c_yel='\033[0;33m'; c_red='\033[0;31m'; c_off='\033[0m'
log()  { echo -e "${c_grn}[+]${c_off} $*"; }
warn() { echo -e "${c_yel}[!]${c_off} $*"; }
die()  { echo -e "${c_red}[x]${c_off} $*" >&2; exit 1; }

need_root() { [[ $EUID -eq 0 ]] || die "run as root (sudo)"; }

# Full package version string for apt/dnf, e.g. 1.31.2-1.1  (empty -> latest)
pkg_version() {
  [[ -n "${K8S_PATCH:-}" ]] || { echo ""; return; }
  echo "${K8S_PATCH}-1.1"
}

# This node's primary IP (advertise addr), config override wins.
node_ip() {
  if [[ -n "${APISERVER_ADVERTISE_ADDRESS:-}" ]]; then
    echo "$APISERVER_ADVERTISE_ADDRESS"
  else
    ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}'
  fi
}

detect_pm() { command -v apt-get >/dev/null && echo apt || { command -v dnf >/dev/null && echo dnf || die "unsupported distro (need apt or dnf)"; }; }
