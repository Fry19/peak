#!/usr/bin/env bash
# Atomic Peak iPhone/derived-data locks. Does not invoke simctl.
# take <slot> <agent> <session> <task> | release <slot> <session> | status
set -euo pipefail

die() { echo "sim-lock: $*" >&2; exit 1; }

device_name() {
  case "$1" in
    codex) echo "Peak Codex iPhone" ;;
    claude) echo "Peak Claude iPhone" ;;
    codex-review) echo "Peak Codex Review iPhone" ;;
    claude-review) echo "Peak Claude Review iPhone" ;;
    codex-temp-*|claude-temp-*)
      local agent=${1%%-temp-*} feature=${1#*-temp-} title
      [[ $feature =~ ^[a-z0-9][a-z0-9-]*$ ]] || return 1
      title="$(printf '%s' "${agent:0:1}" | tr '[:lower:]' '[:upper:]')${agent:1}"
      echo "Peak $title Temp $feature iPhone"
      ;;
    *) return 1 ;;
  esac
}

field() { sed -n "s/^$1: //p" "$2" 2>/dev/null | head -1; }

describe() {
  local dir=$1 epoch
  epoch=$(field epoch "$dir/owner") || epoch=""
  if [[ $epoch =~ ^[0-9]+$ ]]; then
    printf '%s (%s min old)\n' "${dir#/tmp/peak-sim-lock-}" "$(( ($(date +%s) - epoch) / 60 ))"
  else
    printf '%s (owner metadata pending or missing)\n' "${dir#/tmp/peak-sim-lock-}"
  fi
  cat "$dir/owner" 2>/dev/null || true
}

case "${1:-}" in
  take)
    [ $# -eq 5 ] || die "usage: take <slot> <agent> <session> <task>"
    slot=$2
    device=$(device_name "$slot") || die "unknown slot: $slot"
    for value in "$3" "$4" "$5"; do
      [ -n "$value" ] && [[ $value != *$'\n'* ]] || die "owner fields must be nonempty single lines"
    done
    dir=/tmp/peak-sim-lock-$slot
    if ! mkdir "$dir" 2>/dev/null; then
      describe "$dir" >&2
      die "slot is locked; choose a unique <agent>-temp-<feature> slot"
    fi
    printf 'agent: %s\nsession: %s\ntask: %s\nepoch: %s\n' "$3" "$4" "$5" "$(date +%s)" >"$dir/owner"
    echo "Locked $slot: $device; derived data /tmp/peak-$slot"
    echo "If missing, create this exact name using installed simctl device types and runtimes."
    ;;
  release)
    [ $# -eq 3 ] || die "usage: release <slot> <session>"
    slot=$2
    device=$(device_name "$slot") || die "unknown slot: $slot"
    dir=/tmp/peak-sim-lock-$slot
    [ -d "$dir" ] || { echo "$slot is not locked."; exit 0; }
    owner=$(field session "$dir/owner") || die "owner metadata missing; do not reclaim without evidence"
    [ -n "$owner" ] && [ "$owner" = "$3" ] || die "slot belongs to '$owner'; only its owner may release it"
    # Remove only our metadata and the now-empty lock. Refuse unexpected contents.
    [ "$(find "$dir" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" = 1 ] || die "unexpected lock contents; inspect before releasing"
    rm "$dir/owner"
    rmdir "$dir"
    echo "Released $slot. Changed settings must already be restored and $device shut down."
    ;;
  status)
    found=0
    for dir in /tmp/peak-sim-lock-*; do
      [ -d "$dir" ] || continue
      found=1
      describe "$dir"
    done
    [ "$found" -eq 1 ] || echo "No Peak simulator locks held."
    ;;
  *) die "usage: take <slot> <agent> <session> <task> | release <slot> <session> | status" ;;
esac
