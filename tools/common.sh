#!/bin/zsh
set -euo pipefail

script_dir() {
  cd "$(dirname "${(%):-%x}")" && pwd
}

applesauce_root() {
  cd "$(script_dir)/.." && pwd
}

campaign_root() {
  if [[ -n "${APPLE_CAMPAIGN_ROOT:-}" ]]; then
    cd "$APPLE_CAMPAIGN_ROOT" && pwd
    return
  fi

  local root
  root="$(applesauce_root)"
  if [[ -d "$root/../harnesses/ls-stale-state" ]]; then
    cd "$root/.." && pwd
    return
  fi

  echo "Set APPLE_CAMPAIGN_ROOT to the apple campaign checkout." >&2
  exit 2
}

timestamp_utc() {
  date -u +"%Y%m%d-%H%M%SZ"
}

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "missing required command: $cmd" >&2
    exit 2
  fi
}

safe_sw_build_slug() {
  local version build
  version="$(sw_vers -productVersion 2>/dev/null || echo unknown)"
  build="$(sw_vers -buildVersion 2>/dev/null || echo unknown)"
  echo "${version}-${build}"
}

write_sha256_manifest() {
  local dir="$1"
  local out="$2"
  if [[ ! -d "$dir" ]]; then
    echo "missing directory: $dir" > "$out"
    return 0
  fi
  (cd "$dir" && find . -type f -maxdepth 5 -print0 | sort -z | xargs -0 shasum -a 256) > "$out" 2>&1 || true
}
