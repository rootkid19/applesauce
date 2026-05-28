#!/bin/zsh
set -euo pipefail
setopt typeset_silent

source "$(cd "$(dirname "$0")" && pwd)/common.sh"

usage() {
  local code="${1:-2}"
  cat >&2 <<'EOF'
usage:
  reverse_run_ledger.sh append --packet <id> --lane <name> --build-pair <pair> \
    --command <command> --out-path <path> --result <result> \
    --classification <classification> [--notes <text>]

  reverse_run_ledger.sh path

Appends a compact process record to:
  artifacts/run-ledger/run-ledger.tsv
  artifacts/run-ledger/run-ledger.jsonl

This is for research-process bookkeeping only. It does not infer packet status
or vulnerability impact.
EOF
  exit "$code"
}

json_escape() {
  printf "%s" "$1" \
    | tr '\n' ' ' \
    | sed 's/\\/\\\\/g; s/"/\\"/g; s/	/\\t/g'
}

tsv_escape() {
  printf "%s" "$1" | tr '\t\n' '  '
}

cmd="${1:-}"
[[ -n "$cmd" ]] || usage
shift || true

ARTIFACTS="$(artifact_root)"
LEDGER_DIR="$ARTIFACTS/run-ledger"
TSV="$LEDGER_DIR/run-ledger.tsv"
JSONL="$LEDGER_DIR/run-ledger.jsonl"
DATE_BIN="${APPLESAUCE_DATE:-/bin/date}"
mkdir -p "$LEDGER_DIR"

case "$cmd" in
  path)
    print -r -- "$LEDGER_DIR"
    exit 0
    ;;
  append)
    ;;
  -h|--help)
    usage 0
    ;;
  *)
    usage
    ;;
esac

PACKET=""
LANE=""
BUILD_PAIR=""
RUN_COMMAND=""
OUT_PATH=""
RESULT=""
CLASSIFICATION=""
NOTES=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --packet)
      [[ $# -ge 2 ]] || usage
      PACKET="$2"
      shift 2
      ;;
    --lane)
      [[ $# -ge 2 ]] || usage
      LANE="$2"
      shift 2
      ;;
    --build-pair)
      [[ $# -ge 2 ]] || usage
      BUILD_PAIR="$2"
      shift 2
      ;;
    --command)
      [[ $# -ge 2 ]] || usage
      RUN_COMMAND="$2"
      shift 2
      ;;
    --out-path|--output)
      [[ $# -ge 2 ]] || usage
      OUT_PATH="$2"
      shift 2
      ;;
    --result)
      [[ $# -ge 2 ]] || usage
      RESULT="$2"
      shift 2
      ;;
    --classification)
      [[ $# -ge 2 ]] || usage
      CLASSIFICATION="$2"
      shift 2
      ;;
    --notes)
      [[ $# -ge 2 ]] || usage
      NOTES="$2"
      shift 2
      ;;
    -h|--help)
      usage 0
      ;;
    *)
      usage
      ;;
  esac
done

missing=()
[[ -n "$PACKET" ]] || missing+=(--packet)
[[ -n "$LANE" ]] || missing+=(--lane)
[[ -n "$BUILD_PAIR" ]] || missing+=(--build-pair)
[[ -n "$RUN_COMMAND" ]] || missing+=(--command)
[[ -n "$OUT_PATH" ]] || missing+=(--out-path)
[[ -n "$RESULT" ]] || missing+=(--result)
[[ -n "$CLASSIFICATION" ]] || missing+=(--classification)

if [[ ${#missing[@]} -gt 0 ]]; then
  echo "missing required fields: ${missing[*]}" >&2
  exit 2
fi

TS="$("$DATE_BIN" -u +"%Y-%m-%dT%H:%M:%SZ")"

if [[ ! -f "$TSV" ]]; then
  printf "date_utc\tpacket\tlane\tbuild_pair\tclassification\tresult\tout_path\tcommand\tnotes\n" > "$TSV"
fi

printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
  "$(tsv_escape "$TS")" \
  "$(tsv_escape "$PACKET")" \
  "$(tsv_escape "$LANE")" \
  "$(tsv_escape "$BUILD_PAIR")" \
  "$(tsv_escape "$CLASSIFICATION")" \
  "$(tsv_escape "$RESULT")" \
  "$(tsv_escape "$OUT_PATH")" \
  "$(tsv_escape "$RUN_COMMAND")" \
  "$(tsv_escape "$NOTES")" >> "$TSV"

printf '{"date_utc":"%s","packet":"%s","lane":"%s","build_pair":"%s","classification":"%s","result":"%s","out_path":"%s","command":"%s","notes":"%s"}\n' \
  "$(json_escape "$TS")" \
  "$(json_escape "$PACKET")" \
  "$(json_escape "$LANE")" \
  "$(json_escape "$BUILD_PAIR")" \
  "$(json_escape "$CLASSIFICATION")" \
  "$(json_escape "$RESULT")" \
  "$(json_escape "$OUT_PATH")" \
  "$(json_escape "$RUN_COMMAND")" \
  "$(json_escape "$NOTES")" >> "$JSONL"

print -r -- "$LEDGER_DIR"
