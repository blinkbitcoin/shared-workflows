# Shared helper for "regenerate, then fail if that produced any diff" checks
# (codegen.sh, i18n.sh). Source it; do not execute.
# shellcheck shell=bash

# assert_clean_paths PATH... [-- COMMAND...]
# Fails (via die) if any of PATH... has a tracked diff OR an untracked file,
# so a freshly generated file that was never `git add`ed can't slip past a
# plain `git diff --exit-code` (which only sees tracked content).
assert_clean_paths() {
  local paths=("$@")
  local diff_status untracked
  if git diff --exit-code -- "${paths[@]}" >/dev/null; then
    diff_status=0
  else
    diff_status=1
  fi
  untracked=$(git status --porcelain --untracked-files=all -- "${paths[@]}")
  if [ "$diff_status" -ne 0 ] || [ -n "$untracked" ]; then
    {
      echo "generated output is out of date under: ${paths[*]}"
      git diff --stat -- "${paths[@]}"
      [ -n "$untracked" ] && printf 'untracked files:\n%s\n' "$untracked"
    } >&2
    return 1
  fi
}
