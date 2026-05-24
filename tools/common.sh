#!/bin/zsh
set -euo pipefail

script_dir() {
  cd "$(dirname "${(%):-%x}")" && pwd
}

applesauce_root() {
  cd "$(script_dir)/.." && pwd
}

workspace_root() {
  if [[ -n "${APPLESAUCE_WORKSPACE:-}" ]]; then
    cd "$APPLESAUCE_WORKSPACE" && pwd
    return
  fi

  local root
  root="$(applesauce_root)"
  cd "$root/.." && pwd
}

artifact_root() {
  if [[ -n "${APPLESAUCE_ARTIFACTS:-}" ]]; then
    mkdir -p "$APPLESAUCE_ARTIFACTS"
    cd "$APPLESAUCE_ARTIFACTS" && pwd
    return
  fi

  local root
  root="$(workspace_root)/artifacts"
  mkdir -p "$root"
  cd "$root" && pwd
}

harness_root() {
  if [[ -n "${LS_STALE_HARNESS_ROOT:-}" ]]; then
    if [[ -x "$LS_STALE_HARNESS_ROOT/scripts/build.sh" ]]; then
      cd "$LS_STALE_HARNESS_ROOT" && pwd
      return
    fi
    echo "LS_STALE_HARNESS_ROOT is set but missing scripts/build.sh: $LS_STALE_HARNESS_ROOT" >&2
    exit 2
  fi

  local root
  root="$(applesauce_root)/harnesses/ls-stale-state"
  if [[ -x "$root/scripts/build.sh" ]]; then
    cd "$root" && pwd
    return
  fi

  root="$(workspace_root)/harnesses/ls-stale-state"
  if [[ -x "$root/scripts/build.sh" ]]; then
    cd "$root" && pwd
    return
  fi

  cat >&2 <<'EOF'
Missing LS stale-state harness.

Set LS_STALE_HARNESS_ROOT to the harness directory, or place it at either:
  <applesauce>/harnesses/ls-stale-state
  <workspace>/harnesses/ls-stale-state

The directory must contain scripts/build.sh.
EOF
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
  (cd "$dir" && find . -type f -print0 | sort -z | xargs -0 shasum -a 256) > "$out" 2>&1 || true
}
