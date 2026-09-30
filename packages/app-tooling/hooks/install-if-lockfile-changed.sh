#!/usr/bin/env bash
# Reinstall dependencies when a merge or a branch checkout changed the lockfile.
# A git hook for a repository on the baseline; @blinkbitcoin/app-tooling ships it
# as hooks/install-if-lockfile-changed.sh, and lefthook calls it:
#
#   post-merge:    bash <package>/hooks/install-if-lockfile-changed.sh post-merge {1}
#   post-checkout: bash <package>/hooks/install-if-lockfile-changed.sh post-checkout {1} {2} {3}
#
# The hook name comes first and git's own hook arguments after it. Both
# revision pairs are computed here: git hands post-checkout the two refs but
# post-merge only a squash flag, and lefthook's `{1}` templating expands inside
# a YAML string - `HEAD@{1}` became `HEAD@0`, so every merge printed
# `fatal: ambiguous argument 'HEAD@0'` and no install ever ran.
#
# WORKFLOWS_LOCKFILE names the lockfile (default pnpm-lock.yaml) and
# WORKFLOWS_INSTALL_CMD the install (default `pnpm install --frozen-lockfile`).
# The command is split on whitespace into words once, with no globbing, so an
# argument that holds a space needs a wrapper script instead.
set -euo pipefail
# Ask git rather than counting directories up from $0: correct from a
# subdirectory, from a linked worktree, and from node_modules. On a line of its
# own: `set -e` does not stop on a failing `$(...)` inside `cd`'s argument, and
# outside a repository `cd ""` would carry on where it stands.
top="$(git rev-parse --show-toplevel)"
cd "$top"

lockfile="${WORKFLOWS_LOCKFILE:-pnpm-lock.yaml}"
read -ra install_cmd <<<"${WORKFLOWS_INSTALL_CMD:-pnpm install --frozen-lockfile}"

hook="${1:-}"
shift || true

case "$hook" in
  post-merge)
    # The merge commit is already HEAD; ORIG_HEAD is where the branch was.
    old=ORIG_HEAD
    new=HEAD
    ;;
  post-checkout)
    # $1 old ref, $2 new ref, $3 branch flag (0 = file checkout, which leaves
    # HEAD alone and cannot mean "the branch brought a different lockfile").
    [ "${3:-1}" = 1 ] || exit 0
    old="${1:-}"
    new="${2:-}"
    ;;
  *)
    echo "usage: $0 post-merge <squash-flag> | post-checkout <old> <new> <flag>" >&2
    exit 2
    ;;
esac

# A null ref (the first checkout of a fresh clone) or a missing ORIG_HEAD (a
# fast-forward pull with nothing to merge) has nothing to compare against.
for rev in "$old" "$new"; do
  git rev-parse --verify --quiet "$rev^{commit}" >/dev/null || exit 0
done

# `git diff --quiet`, not `git diff --name-only | grep -q .`: `grep -q` exits on
# its first match and can kill the still-writing git with SIGPIPE, which under
# `set -o pipefail` reports 141 and silently skips the install.
if ! git diff --quiet "$old" "$new" -- "$lockfile"; then
  echo "$lockfile changed: ${install_cmd[*]}"
  "${install_cmd[@]}"
fi
