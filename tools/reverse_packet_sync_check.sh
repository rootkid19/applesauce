#!/bin/zsh
set -euo pipefail
setopt typeset_silent

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

usage() {
  local code="${1:-2}"
  cat >&2 <<'EOF'
usage:
  reverse_packet_sync_check.sh [-o <report.md>] [--no-fail]

Checks Chimera Apple packet state for obvious active/parked drift across:
  ACTIVE_TARGET.md
  LANDSCAPE.md
  FUTURE-REVISIONS.md
  packets/*.md

The checker is intentionally conservative. It reports stale-state smells and
does not infer vulnerability status.
EOF
  exit "$code"
}

OUT=""
NO_FAIL=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--out)
      [[ $# -ge 2 ]] || usage
      OUT="$2"
      shift 2
      ;;
    --no-fail)
      NO_FAIL=1
      shift
      ;;
    -h|--help)
      usage 0
      ;;
    *)
      usage
      ;;
  esac
done

WORKSPACE="$(workspace_root)"
ARTIFACTS="$(artifact_root)"
ACTIVE_FILE="$WORKSPACE/ACTIVE_TARGET.md"
LANDSCAPE_FILE="$WORKSPACE/LANDSCAPE.md"
FUTURE_FILE="$WORKSPACE/FUTURE-REVISIONS.md"
PACKETS_DIR="$WORKSPACE/packets"
AWK_BIN="${APPLESAUCE_AWK:-/usr/bin/awk}"
DATE_BIN="${APPLESAUCE_DATE:-/bin/date}"
GREP_BIN="${APPLESAUCE_GREP:-/usr/bin/grep}"
SED_BIN="${APPLESAUCE_SED:-/usr/bin/sed}"
SORT_BIN="${APPLESAUCE_SORT:-/usr/bin/sort}"

if [[ -z "$OUT" ]]; then
  OUT="$ARTIFACTS/process/packet-sync-check.md"
fi
mkdir -p "$(dirname "$OUT")"

WARNINGS=0
INFOS=0
TMP_DIR="${TMPDIR:-/tmp}/applesauce-packet-sync.$$"
mkdir -p "$TMP_DIR"
trap 'rm -rf "$TMP_DIR"' EXIT

first_packet_ref() {
  local file="$1"
  if [[ -f "$file" ]]; then
    "$GREP_BIN" -Eom 1 'Packet [0-9][0-9][0-9]' "$file" 2>/dev/null || true
  fi
}

lower() {
  print -r -- "$1" | tr '[:upper:]' '[:lower:]'
}

status_class() {
  local status_l
  status_l="$(lower "$1")"
  if [[ "$status_l" == *"active"* && "$status_l" != *"not active"* ]]; then
    print -r -- "active"
  elif [[ "$status_l" == *"parked"* || "$status_l" == *"ruled out"* || "$status_l" == *"calibration"* || "$status_l" == *"non-promoting"* ]]; then
    print -r -- "parked"
  else
    print -r -- "unknown"
  fi
}

record_warning() {
  WARNINGS=$(( WARNINGS + 1 ))
  print -r -- "- WARNING: $*" >> "$TMP_DIR/findings.md"
}

record_info() {
  INFOS=$(( INFOS + 1 ))
  print -r -- "- INFO: $*" >> "$TMP_DIR/findings.md"
}

ACTIVE_PACKET="$(first_packet_ref "$ACTIVE_FILE")"
LANDSCAPE_PACKET="$(
  if [[ -f "$LANDSCAPE_FILE" ]]; then
    "$AWK_BIN" '
      /Primary target:/ { seen=1; next }
      seen && /Packet [0-9][0-9][0-9]/ {
        if (match($0, /Packet [0-9][0-9][0-9]/)) {
          print substr($0, RSTART, RLENGTH)
          exit
        }
      }
    ' "$LANDSCAPE_FILE"
  fi
)"
FUTURE_ACTIVE="$(
  if [[ -f "$FUTURE_FILE" ]]; then
    "$AWK_BIN" -F '|' '
      /Active target/ && /Packet|002|003|004|005|006|001/ {
        for (i = 1; i <= NF; i++) {
          if ($i ~ /[0-9][0-9][0-9]/) {
            gsub(/^[ \t]+|[ \t]+$/, "", $i)
            print "Packet " substr($i, 1, 3)
            exit
          }
        }
      }
    ' "$FUTURE_FILE"
  fi
)"

: > "$TMP_DIR/findings.md"

if [[ -z "$ACTIVE_PACKET" ]]; then
  record_warning "Could not parse selected packet from ACTIVE_TARGET.md."
fi

if [[ -n "$LANDSCAPE_PACKET" && -n "$ACTIVE_PACKET" && "$LANDSCAPE_PACKET" != "$ACTIVE_PACKET" ]]; then
  record_warning "ACTIVE_TARGET selects $ACTIVE_PACKET but LANDSCAPE primary target is $LANDSCAPE_PACKET."
fi

if [[ -n "$FUTURE_ACTIVE" && -n "$ACTIVE_PACKET" && "$FUTURE_ACTIVE" != "$ACTIVE_PACKET" ]]; then
  record_warning "FUTURE-REVISIONS active posture says $FUTURE_ACTIVE but ACTIVE_TARGET selects $ACTIVE_PACKET."
fi

{
  printf "packet\tfile\tstatus_class\tstatus\n"
  for packet_file in "$PACKETS_DIR"/*.md; do
    [[ -f "$packet_file" ]] || continue
    [[ "$(basename "$packet_file")" == "CLAUDE.md" ]] && continue
    local_id="$(basename "$packet_file" | "$SED_BIN" -n 's/^\([0-9][0-9][0-9]\)-.*/\1/p')"
    [[ -n "$local_id" ]] || continue
    status_line="$("$SED_BIN" -n 's/^Status:[[:space:]]*//p' "$packet_file" | head -1)"
    [[ -n "$status_line" ]] || status_line="missing"
    class="$(status_class "$status_line")"
    printf "Packet %s\t%s\t%s\t%s\n" "$local_id" "${packet_file#$WORKSPACE/}" "$class" "$status_line"
  done
} > "$TMP_DIR/packet-status.tsv"

while IFS=$'\t' read -r packet file class status_text; do
  [[ "$packet" == "packet" ]] && continue
  if [[ "$packet" == "$ACTIVE_PACKET" ]]; then
    if [[ "$class" != "active" ]]; then
      record_warning "$packet is selected active, but $file status is '$status_text'."
    fi
  else
    if [[ "$class" == "active" ]]; then
      record_warning "$packet is not selected active, but $file status is '$status_text'."
    fi
  fi
done < "$TMP_DIR/packet-status.tsv"

if [[ -f "$FUTURE_FILE" ]]; then
  STALE_LINES="$("$GREP_BIN" -Ein 'Live high-value|actively investigating|Needs corrected|tooling prepared|if Packet 006 MCM does not promote|corrected probe is complete|next bounded question' "$FUTURE_FILE" || true)"
  if [[ -n "$STALE_LINES" ]]; then
    record_warning "FUTURE-REVISIONS contains stale live-lane phrasing: $(print -r -- "$STALE_LINES" | tr '\n' '; ')"
  fi
fi

if [[ $WARNINGS -eq 0 ]]; then
  record_info "No active/parked drift detected by conservative checks."
fi

{
  print -r -- "# Packet Sync Check"
  print -r -- ""
  print -r -- "Date: $("$DATE_BIN" -u +"%Y-%m-%dT%H:%M:%SZ")"
  print -r -- ""
  print -r -- "Workspace: \`$WORKSPACE\`"
  print -r -- ""
  print -r -- "Selected active packet: \`${ACTIVE_PACKET:-unknown}\`"
  print -r -- "LANDSCAPE primary packet: \`${LANDSCAPE_PACKET:-unknown}\`"
  print -r -- "FUTURE active packet: \`${FUTURE_ACTIVE:-unknown}\`"
  print -r -- ""
  print -r -- "## Findings"
  print -r -- ""
  cat "$TMP_DIR/findings.md"
  print -r -- ""
  print -r -- "## Packet Status Table"
  print -r -- ""
  print -r -- "| Packet | File | Class | Status |"
  print -r -- "| --- | --- | --- | --- |"
  while IFS=$'\t' read -r packet file class status_text; do
    [[ "$packet" == "packet" ]] && continue
    printf "| %s | \`%s\` | %s | %s |\n" "$packet" "$file" "$class" "$status_text"
  done < "$TMP_DIR/packet-status.tsv"
} > "$OUT"

print -r -- "$OUT"
if [[ $WARNINGS -gt 0 && $NO_FAIL -eq 0 ]]; then
  exit 1
fi
