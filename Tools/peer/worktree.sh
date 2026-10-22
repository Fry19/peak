#!/usr/bin/env bash
# Peer worktrees holding a snapshot of the lead's checkout, including staged,
# unstaged, deleted, and untracked files (AGENTS.md "Worktree handoff").
# Run from the lead's checkout. Peers only edit files; the lead runs these.
#
#   worktree.sh create <lead> <peer> <feature> <owned paths...>
#   worktree.sh export <lead> <peer> <feature>    # writes the peer's owned-path patch; you apply it
#   worktree.sh remove <lead> <peer> <feature> [--force]
#
# Worktree: /tmp/peak-worktrees/<peer>-<feature>
# Notes:    /tmp/peak-review/<lead>-<feature> (snapshot, owned paths, patches)
set -euo pipefail
trap 'echo "worktree: failed at line $LINENO" >&2' ERR

die() { echo "worktree: $*" >&2; exit 1; }

[ $# -ge 4 ] || die "usage: create|export|remove <lead> <peer> <feature> ..."
cmd=$1 lead=$2 peer=$3 feature=$4
shift 4
for name in "$lead" "$peer" "$feature"; do
  [[ $name =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "names must be lowercase words joined by hyphens: '$name'"
done

ROOT=$(git rev-parse --show-toplevel)
cd "$ROOT"
WT=/tmp/peak-worktrees/$peer-$feature
P=/tmp/peak-review/$lead-$feature
OWNED=$P/owned-$peer.txt

# Files the peer changed since the snapshot, tracked or untracked. Returns nonzero if git
# fails (command substitutions don't inherit set -e in bash 3.2, so check each call).
changed_files() {
  local sha tracked untracked
  sha=$(cat "$P/snapshot-sha") || return 1
  tracked=$(git -C "$WT" diff --name-only "$sha") || return 1
  untracked=$(git -C "$WT" ls-files -o --exclude-standard) || return 1
  printf '%s\n%s\n' "$tracked" "$untracked" | sed '/^$/d' | sort -u
}

# True when the worktree copy matches the checkout: symlink target, or mode and contents.
same_file() {
  local a=$WT/$1 b=$ROOT/$1
  if [ -L "$a" ] || [ -L "$b" ]; then
    [ -L "$a" ] && [ -L "$b" ] && [ "$(readlink "$a")" = "$(readlink "$b")" ]
    return
  fi
  [ -e "$b" ] && [ "$(stat -f %Lp "$a")" = "$(stat -f %Lp "$b")" ] && cmp -s "$a" "$b"
}

is_owned() {
  local file=$1 path
  while IFS= read -r path; do
    path=${path%/}
    [ -n "$path" ] || continue
    if [ "$file" = "$path" ] || [[ $file == "$path"/* ]]; then return 0; fi
  done <"$OWNED"
  return 1
}

case "$cmd" in
  create)
    [ $# -ge 1 ] || die "list the paths the peer owns (use the reviewed files for a read-only review)"
    for path in "$@"; do
      case "$path" in
        ''|.|..|/*|../*|*/../*|*/..|.git|.git/*|:*) die "owned paths must be explicit repository-relative files or directories: '$path'" ;;
      esac
    done
    [ ! -e "$WT" ] || die "$WT already exists; remove it first"
    mkdir -p "$P" /tmp/peak-worktrees
    git worktree add --detach "$WT" HEAD >/dev/null
    git diff --binary HEAD >"$P/snapshot.patch"
    if [ -s "$P/snapshot.patch" ]; then git -C "$WT" apply "$P/snapshot.patch"; fi
    git ls-files -z -o --exclude-standard | rsync -a0R --files-from=- ./ "$WT"/
    git -C "$WT" add -A
    git -C "$WT" -c core.hooksPath=/dev/null -c commit.gpgsign=false commit -q --allow-empty -m "Snapshot of the lead's checkout"
    git -C "$WT" rev-parse HEAD >"$P/snapshot-sha"
    printf '%s\n' "$@" >"$OWNED"
    echo "Worktree $WT at snapshot $(cut -c1-7 "$P/snapshot-sha")"
    echo "Peer owns: $*"
    ;;
  export)
    [ -f "$P/snapshot-sha" ] && [ -f "$OWNED" ] || die "no worktree notes in $P; run create first"
    owned=()
    while IFS= read -r path; do [ -n "$path" ] && owned+=("$path"); done <"$OWNED"
    git --literal-pathspecs -C "$WT" add -A -- "${owned[@]}"
    patch=$P/fixes-$peer.patch
    git --literal-pathspecs -C "$WT" diff --cached --binary "$(cat "$P/snapshot-sha")" -- "${owned[@]}" >"$patch"
    files=$(changed_files) || die "couldn't list the peer's changes"
    outside=()
    while IFS= read -r file; do
      [ -n "$file" ] && ! is_owned "$file" && outside+=("$file")
    done <<<"$files"
    if [ ${#outside[@]} -gt 0 ]; then
      echo "Not exported (outside the peer's owned paths); review and apply by hand only if worth keeping:"
      printf '  %s\n' "${outside[@]}"
    fi
    if [ ! -s "$patch" ]; then echo "No changes in owned paths."; exit 0; fi
    git apply --stat "$patch"
    if git apply --check "$patch" 2>/dev/null; then
      echo "Read $patch, then apply it with: git apply $patch"
    else
      echo "$patch does not apply cleanly; the checkout changed since the snapshot."
      echo "Apply the overlapping hunks by hand without overwriting other work."
    fi
    ;;
  remove)
    [ -d "$WT" ] || { echo "$WT does not exist."; exit 0; }
    force=0
    [ "${1:-}" = "--force" ] && force=1
    if [ ! -f "$P/snapshot-sha" ]; then
      [ $force -eq 1 ] || die "no snapshot notes in $P, so unapplied edits can't be checked; inspect $WT, then rerun with --force"
    else
      files=$(changed_files) || die "couldn't list the peer's changes; nothing removed"
      unapplied=()
      while IFS= read -r file; do
        [ -n "$file" ] || continue
        if [ -e "$WT/$file" ] || [ -L "$WT/$file" ]; then
          same_file "$file" || unapplied+=("$file")
        elif [ -e "$ROOT/$file" ] || [ -L "$ROOT/$file" ]; then
          unapplied+=("$file")
        fi
      done <<<"$files"
      if [ ${#unapplied[@]} -gt 0 ] && [ $force -eq 0 ]; then
        echo "These peer edits differ from your checkout (not applied, or the file changed again since):"
        printf '  %s\n' "${unapplied[@]}"
        die "apply what's worth keeping, then rerun with --force to discard the rest"
      fi
    fi
    git worktree remove --force "$WT"
    echo "Removed $WT"
    ;;
  *) die "unknown command '$cmd'" ;;
esac
