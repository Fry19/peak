#!/usr/bin/env bash
# Starts or resumes a peer agent session with the right flags for each direction.
# Run from the lead's checkout; it can take minutes, so run it in the background.
#
#   ask.sh <codex|claude> <consult|review|task> <feature> <dir> <prompt-file> [screenshot...]
#   ask.sh resume <feature> <session-id> <prompt-file> [screenshot...]
#
# consult: read-only in <dir> (the lead's checkout), also when resumed.
# review/task: may edit <dir> (the peer's worktree) and use its assigned simulators.
# Each attempt gets its own folder, /tmp/peak-review/<lead>-<feature>/<kind>-<n>/ (prompt.md,
# reply.md, output.json, stderr.txt). Sessions are recorded in sessions.tsv there, and a line is
# added to .agents/collab-log/; fill in its "changed outcome".
set -euo pipefail
trap 'echo "ask: failed at line $LINENO" >&2' ERR

CODEX=${PEAK_CODEX_BIN:-$(command -v codex || printf '%s' /Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex)}
CLAUDE=${PEAK_CLAUDE_BIN:-$(command -v claude || printf '%s' "$HOME/.local/bin/claude")}
ROOT=$(git rev-parse --show-toplevel)

die() { echo "ask: $*" >&2; exit 1; }

claude_flags() { # <kind>
  if [ "$1" = consult ]; then
    printf '%s\n' --tools 'Read,Glob,Grep,Bash' \
      --allowedTools Read Glob Grep 'Bash(git diff *)' 'Bash(git status *)' 'Bash(git log *)' 'Bash(git show *)' \
      --disallowedTools 'Bash(xcodebuild *)' 'Bash(xcrun simctl *)' 'Bash(axe *)' \
      --permission-mode dontAsk
  else
    printf '%s\n' --permission-mode acceptEdits
  fi
}

if [ "${1:-}" = resume ]; then
  [ $# -ge 4 ] || die "usage: resume <feature> <session-id> <prompt-file> [screenshot...]"
  feature=$2 id=$3 prompt=$4
  shift 4
  line=""
  for sessions in /tmp/peak-review/claude-"$feature"/sessions.tsv /tmp/peak-review/codex-"$feature"/sessions.tsv; do
    if [ -z "$line" ] && [ -f "$sessions" ]; then
      line=$(awk -F'\t' -v id="$id" '$1 == id' "$sessions" | tail -1)
    fi
  done
  [ -n "$line" ] || die "no session $id recorded for '$feature'"
  IFS=$'\t' read -r _ peer kind dir lead <<<"$line"
  mode=resume
else
  [ $# -ge 5 ] || die "usage: <codex|claude> <consult|review|task> <feature> <dir> <prompt-file> [screenshot...]"
  peer=$1 kind=$2 feature=$3 dir=$4 prompt=$5
  shift 5
  case "$peer" in codex) lead=claude ;; claude) lead=codex ;; *) die "peer must be codex or claude" ;; esac
  case "$kind" in consult | review | task) ;; *) die "kind must be consult, review, or task" ;; esac
  mode=start
fi
[[ $feature =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "feature must be lowercase words joined by hyphens"
case "$peer" in
  codex) [ -x "$CODEX" ] || die "Codex CLI unavailable: $CODEX" ;;
  claude) [ -x "$CLAUDE" ] || die "Claude CLI unavailable: $CLAUDE" ;;
esac
# Absolute paths, because the peer runs from <dir>.
abs() { case "$1" in /*) echo "$1" ;; *) echo "$PWD/$1" ;; esac; }
[ -f "$prompt" ] || die "prompt file not found: $prompt"
prompt=$(abs "$prompt")
[ -d "$dir" ] || die "directory not found: $dir"
dir=$(cd "$dir" && pwd)
shots=()
for image in "$@"; do
  [ -f "$image" ] || die "screenshot not found: $image"
  shots+=("$(abs "$image")")
done

P=/tmp/peak-review/$lead-$feature
mkdir -p "$P"
# Reserve the attempt folder atomically, so failed and concurrent runs keep their own files.
n=1
while ! mkdir "$P/$kind-$n" 2>/dev/null; do
  n=$((n + 1))
  [ $n -le 100 ] || die "can't create an attempt folder in $P"
done
A=$P/$kind-$n
out=$A/reply.md raw=$A/output.json err=$A/stderr.txt
cp "$prompt" "$A/prompt.md"
case "$kind" in consult) sandbox=read-only ;; *) sandbox=workspace-write ;; esac

start=$(date +%s)
status=0
if [ "$peer" = codex ]; then
  images=()
  for image in ${shots[@]+"${shots[@]}"}; do images+=(-i "$image"); done
  if [ $mode = start ]; then
    # No positional prompt: codex reads it from stdin, and -i can't swallow it.
    "$CODEX" exec -C "$dir" -s "$sandbox" --json -o "$out" ${images[@]+"${images[@]}"} <"$prompt" >"$raw" 2>"$err" || status=$?
  else
    # Resume doesn't keep the original sandbox, so set it again.
    (cd "$dir" && "$CODEX" exec resume --json -o "$out" -c "sandbox_mode=\"$sandbox\"" "$id" - ${images[@]+"${images[@]}"}) <"$prompt" >"$raw" 2>"$err" || status=$?
  fi
  [ $mode = resume ] || id=$(python3 -I -c 'import json,sys
for line in open(sys.argv[1]):
    try: event = json.loads(line)
    except ValueError: continue
    if event.get("thread_id"): print(event["thread_id"]); break' "$raw")
else
  # Claude opens screenshots with Read, so list their paths in the prompt.
  full=$A/prompt.md
  if [ ${#shots[@]} -gt 0 ]; then
    printf '\nScreenshots (open each with Read):\n' >>"$full"
    printf -- '- %s\n' "${shots[@]}" >>"$full"
  fi
  flags=()
  while IFS= read -r flag; do flags+=("$flag"); done < <(claude_flags "$kind")
  resume_flags=()
  [ $mode = start ] || resume_flags=(--resume "$id")
  (cd "$dir" && "$CLAUDE" -p ${resume_flags[@]+"${resume_flags[@]}"} "${flags[@]}" --output-format json) <"$full" >"$raw" 2>"$err" || status=$?
  parsed=$(python3 -I -c 'import json,sys
data = json.load(open(sys.argv[1]))
open(sys.argv[2], "w").write(data.get("result") or "")
print(data.get("session_id") or "")
sys.exit(1 if data.get("is_error") else 0)' "$raw" "$out" 2>/dev/null) || status=1
  [ $mode = resume ] || id=$parsed
fi
minutes=$(( ($(date +%s) - start + 30) / 60 ))
if [ -n "${id:-}" ]; then
  [ $mode = resume ] || printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$peer" "$kind" "$dir" "$lead" >>"$P/sessions.tsv"
else
  id=unavailable
  [ "$status" -ne 0 ] || status=1
fi

# One log file per task, so concurrent sessions never edit the same file.
mkdir -p "$ROOT/.agents/collab-log"
log=$(ls -t "$ROOT"/.agents/collab-log/*-"$lead-$feature".md 2>/dev/null | head -1 || true)
if [ -z "$log" ]; then
  log=$ROOT/.agents/collab-log/$(TZ="${PEAK_LOG_TZ:-America/New_York}" date +%F)-$lead-$feature.md
  printf '# %s (%s lead)\n\n' "$feature" "$lead" >"$log"
fi
label=$kind
[ $mode = start ] || label="$kind (resumed)"
echo "- $label · $peer · ${minutes} min · exit: $status · changed outcome: ? · ${id:0:13}" >>"$log"

echo "$peer $label finished in ${minutes} min (exit $status). Session: $id"
echo "Reply: $out"
echo "Log: $log (replace the ? with y/n and a short note)"
exit $status
