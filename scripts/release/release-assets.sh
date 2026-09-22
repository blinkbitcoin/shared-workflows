#!/usr/bin/env bash
# Create or move a GitHub release and attach the fixed release asset set.
#
# Usage: release-assets.sh MODE
#   create-prerelease  create (or update) $TAG as a pre-release at $TARGET_SHA.
#                      $TARGET_SHA applies to *creation* only: once the tag
#                      exists, GitHub ignores a release's target_commitish, so
#                      a re-run after a force-push updates the release but
#                      leaves the tag on the original commit. Delete the tag if
#                      it really has to move.
#   promote            take $TAG out of pre-release, without making it latest
#   latest             take $TAG out of pre-release and mark it latest
#   append             append a section to $TAG's existing body (body only:
#                      this mode uploads nothing and does not touch SHA256SUMS)
#
# Every mode except `append` uploads whatever of the fixed asset set is present in
# $WORKFLOWS_ASSETS_DIR (`--clobber`, so re-running a stage is safe) together with a
# freshly computed SHA256SUMS. The list is fixed on purpose: a release whose
# assets vary run to run cannot be verified by a downstream script.
#
# `promote` also carries assets forward: with $FROM_TAG set it downloads every
# asset of that pre-release, so the promoted release ships the exact binaries
# that were tested rather than a rebuild. $DELETE_SOURCE then removes the
# pre-release and its tag once the upload has succeeded.
#
# The carried-forward files never overwrite this run's: they land in a scratch
# directory and are copied into $WORKFLOWS_ASSETS_DIR only where no file of that name
# is already there. Both sides carry build-info.json, store-notes.json,
# notes-store.txt and notes.md, and the source is by definition an *earlier*
# stage - promoting a beta from an internal pre-release with --clobber shipped
# the internal run's `"stage": "internal"` build-info and its commit-derived
# notes on the beta release, and handed that same build-info to the OTA
# fingerprint gate downstream as its baseline.
#
# Env: TAG (required), TITLE, TARGET_SHA, NOTES_FILE, APPEND_TITLE, FROM_TAG,
#      DELETE_SOURCE, WORKFLOWS_ASSETS_DIR (default $WORKFLOWS_OUT/assets), GH_TOKEN,
#      GH_REPO.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
source "$(dirname "$0")/../lib/release-env.sh"
source "$(dirname "$0")/../lib/body-section.sh"
require_cmd gh

mode="${1:?usage: release-assets.sh create-prerelease|promote|latest|append}"
tag="${TAG:?release-assets.sh needs TAG}"
assets_dir="${WORKFLOWS_ASSETS_DIR:-$WORKFLOWS_OUT/assets}"

# The body scratch files sit in $RUNNER_TEMP and would die with the runner, but
# a local run should not litter and a leftover body must never be picked up by
# a later invocation.
body_file="${RUNNER_TEMP:-/tmp}/workflows-release-body.md"
stripped_file="$body_file.stripped"
# Where a $FROM_TAG release's assets are staged before being merged in.
carry_dir="${RUNNER_TEMP:-/tmp}/workflows-carry-assets"
trap 'rm -f "$body_file" "$stripped_file" "${RUNNER_TEMP:-/tmp}/workflows-release-note.md"; rm -rf "$carry_dir"' EXIT

# The fixed asset set, as basename globs. Anything else in the directory is
# deliberately ignored rather than silently published.
ASSET_GLOBS=(
  'build-info.json'
  'store-notes.json'
  'notes-store.txt'
  'notes.md'
  '*.ipa'
  '*.aab'
  '*.apk'
  '*.dSYM.zip'
  'dsyms.zip'
  'mapping.txt'
)

assets=()
# collect_assets [DIR] - fill $assets with the fixed set found in DIR
# (default $assets_dir).
collect_assets() {
  local dir="${1:-$assets_dir}" g f
  assets=()
  [ -d "$dir" ] || return 0
  for g in "${ASSET_GLOBS[@]}"; do
    # Unquoted on purpose: $g is the glob pattern being expanded.
    # shellcheck disable=SC2086
    for f in "$dir"/$g; do
      if [ -f "$f" ]; then assets+=("$f"); fi
    done
  done
  # Explicit: the loop's last `[ -f ]` is the function's exit status otherwise,
  # and a non-matching final glob would abort the caller under errexit.
  return 0
}

sha256_of() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1"; else sha256sum "$1"; fi
}

# `gh release view >/dev/null 2>&1` collapses three different answers into one
# failing status: the release is genuinely absent, the API refused us (403), we
# were rate-limited (429), or the network dropped. Treating all of those as
# "absent" is what let a blip read as "already promoted and deleted" and carry a
# promote straight past the guard that refuses to publish an empty release.
#
# So: a 404 is an answer, and anything else is not. The message is matched rather
# than the status because `gh release view` exits 1 for every failure; the
# spellings below cover gh's own wording and the raw API's.
#
# Prints `present` or `absent` and returns 0 when it could tell; returns 1 when
# it could not, leaving the caller to decide (every caller here treats that as
# fatal, because guessing is what caused the problem).
release_state() {
  local t="$1" err rc
  err="$(gh release view "$t" 2>&1 >/dev/null)"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    printf 'present\n'
    return 0
  fi
  case "$err" in
    *'release not found'* | *'Release not found'* | *'Not Found'* | *'HTTP 404'*)
      printf 'absent\n'
      return 0
      ;;
  esac
  log "::error::could not determine whether release $t exists: $err"
  return 1
}

# True only when the release is known to exist. A lookup that could not be made
# is fatal here rather than false: "we could not ask" must never become "it is
# not there".
release_exists() {
  local state
  state="$(release_state "$tag")" ||
    die "could not check whether release $tag exists - refusing to guess"
  [ "$state" = present ]
}

# upload_assets [required]
#
# With `required`, an empty asset set is fatal. `promote` and `latest` pass it:
# both take a release out of pre-release, and doing that with no binaries
# attached publishes an empty release to users - and under promote's
# DELETE_SOURCE the tested bytes are deleted right afterwards. There was a guard
# for exactly this, but it sat inside the carry-forward branch, so any path that
# skipped that branch (including a failed $FROM_TAG lookup) walked past it.
#
# create-prerelease stays permissive: it legitimately runs before a platform has
# finished building, and the assets arrive on a later re-run with --clobber.
upload_assets() {
  local required="${1:-}" a
  collect_assets
  if [ "${#assets[@]}" -eq 0 ]; then
    if [ "$required" = required ]; then
      die "no release assets found in $assets_dir; refusing to publish $tag as an empty release"
    fi
    log "no release assets found in $assets_dir - nothing to upload"
    return 0
  fi
  # Basenames only: the checksum file ships next to the assets on the release
  # page, where the absolute path of a runner's temp directory is noise.
  (
    cd "$assets_dir"
    : > SHA256SUMS
    for a in "${assets[@]}"; do sha256_of "$(basename "$a")" >> SHA256SUMS; done
  )
  assets+=("$assets_dir/SHA256SUMS")
  group "upload ${#assets[@]} assets to $tag"
  gh release upload "$tag" "${assets[@]}" --clobber
  endgroup
}

# Optional gh flags are built as arrays so an unset variable contributes no
# argument at all (an empty quoted "" would become a literal empty argument).
title_args=()
[ -z "${TITLE:-}" ] || title_args=(--title "$TITLE")
notes_args=()
if [ -n "${NOTES_FILE:-}" ] && [ -f "$NOTES_FILE" ]; then
  notes_args=(--notes-file "$NOTES_FILE")
fi

# $BODY_NOTE goes at the top of the body, at creation time. It exists so a
# release can say something about itself that the notes cannot know - today,
# that store uploads were switched off and this build never reached a store.
#
# At creation rather than through a follow-up `append`: an appended marker
# leaves a window, however short, in which the release reads as an ordinary
# store build, and anyone watching the releases page during that window is
# misled by a release we deliberately marked.
#
# With no notes file, `--generate-notes` and a notes file combine: gh prepends
# the provided notes to the ones it generates, which is exactly the shape
# wanted here ("Additional release notes can be prepended", gh release create
# --help). So both paths end up with the note first and the real notes below.
# Recorded before $BODY_NOTE rewrites notes_args below: the create path decides
# whether to ask gh to generate notes by checking whether any were supplied, and
# a note alone must not be mistaken for supplied notes.
had_notes_file=false
[ "${#notes_args[@]}" -eq 0 ] || had_notes_file=true

if [ -n "${BODY_NOTE:-}" ]; then
  note_file="${RUNNER_TEMP:-/tmp}/workflows-release-note.md"
  {
    printf '> [!NOTE]\n'
    # One blockquote line per input line, so a multi-line note stays inside the
    # admonition rather than half of it falling out into the body.
    while IFS= read -r line; do printf '> %s\n' "$line"; done <<< "$BODY_NOTE"
    printf '\n'
  } > "$note_file"
  if [ "$had_notes_file" = true ]; then
    cat "$NOTES_FILE" >> "$note_file"
  fi
  notes_args=(--notes-file "$note_file")
  # The same fact in the run summary. The release body is the durable record,
  # but someone looking at a green run wants to know there and then that it did
  # not do what a release run usually does, without opening the release.
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
      printf '### %s\n\n' "$tag"
      printf '%s\n' "$BODY_NOTE"
    } >> "$GITHUB_STEP_SUMMARY"
  fi
fi
# `--target` creates the tag; a tag that already exists (reserved in Prepare,
# see reserve-tag.sh) is used as it is, which creates no ref and so cannot be
# refused by GitHub's rule about tags on commits whose workflow files differ
# from the default branch tip.
tag_exists() { gh api "repos/${GH_REPO:?GH_REPO not set}/git/ref/tags/$tag" >/dev/null 2>&1; }
target_args=()
if [ -n "${TARGET_SHA:-}" ]; then
  if tag_exists; then
    log "tag $tag already exists - creating the release on it, no --target"
  else
    target_args=(--target "$TARGET_SHA")
  fi
fi

case "$mode" in
  create-prerelease)
    if release_exists; then
      log "release $tag already exists - updating it in place"
      gh release edit "$tag" --prerelease --draft=false "${title_args[@]+"${title_args[@]}"}" \
        "${notes_args[@]+"${notes_args[@]}"}"
    else
      # `--generate-notes` alongside a notes file is deliberate, not a conflict:
      # gh prepends the supplied notes to the generated ones, so a body note
      # lands above real release notes instead of replacing them.
      if [ "$had_notes_file" = false ]; then
        notes_args+=(--generate-notes)
      fi
      gh release create "$tag" --prerelease \
        "${title_args[@]+"${title_args[@]}"}" \
        "${target_args[@]+"${target_args[@]}"}" \
        "${notes_args[@]}"
    fi
    upload_assets
    ;;
  promote)
    release_exists || die "release $tag does not exist - run create-prerelease first"
    if [ -n "${FROM_TAG:-}" ]; then
      mkdir -p "$assets_dir"
      # A re-run of a promote that already deleted its source must not fail:
      # the assets are on the target release by then, so a missing source is
      # information, not an error. A lookup that *failed* is a different thing
      # entirely and is fatal - taking that branch skips the empty-release guard
      # below and publishes whatever happens to be lying in $assets_dir.
      from_state="$(release_state "$FROM_TAG")" ||
        die "could not check whether $FROM_TAG exists - refusing to promote on a guess"
      if [ "$from_state" = present ]; then
        group "carry assets forward from $FROM_TAG"
        rm -rf "$carry_dir"
        mkdir -p "$carry_dir"
        gh release download "$FROM_TAG" --dir "$carry_dir" --clobber ||
          die "could not download the assets of $FROM_TAG"
        collect_assets "$carry_dir"
        # An empty carry is fatal, and fatal *here*: one step further on, the
        # release would be taken out of pre-release with no binaries attached
        # and, with DELETE_SOURCE, the tested bytes deleted right after. This is
        # what a from-tag pointing at a release that never got its assets (a
        # BUILD_NUMBER_OFFSET changed between stages, say) looks like.
        [ "${#assets[@]}" -gt 0 ] ||
          die "$FROM_TAG carries none of the expected release assets; refusing to promote an empty release"
        for f in "${assets[@]}"; do
          if [ -e "$assets_dir/$(basename "$f")" ]; then
            log "keeping this run's $(basename "$f") - not overwriting it with $FROM_TAG's copy"
          else
            cp "$f" "$assets_dir/"
          fi
        done
        ls -l "$assets_dir" >&2
        endgroup
      else
        log "source pre-release $FROM_TAG does not exist (already promoted and deleted?) - continuing with whatever is in $assets_dir"
      fi
    fi
    # --latest=false on purpose: promoting a staged build out of pre-release is
    # not the same decision as declaring it the latest release.
    gh release edit "$tag" --prerelease=false --latest=false "${title_args[@]+"${title_args[@]}"}"
    # SHA256SUMS is regenerated here over the merged set (carried-forward assets
    # plus this run's), so it describes the release that actually exists.
    upload_assets required
    # Only after the upload succeeded: deleting the source first would leave no
    # copy of the binaries anywhere if the upload then failed.
    if [ -n "${FROM_TAG:-}" ] && [ "${DELETE_SOURCE:-false}" = "true" ]; then
      from_state="$(release_state "$FROM_TAG")" ||
        die "could not check whether $FROM_TAG still exists - refusing to guess before a delete"
      if [ "$from_state" = present ]; then
        group "delete source pre-release $FROM_TAG"
        gh release delete "$FROM_TAG" --yes --cleanup-tag
        endgroup
      else
        log "source pre-release $FROM_TAG is already gone - nothing to delete"
      fi
    fi
    ;;
  latest)
    release_exists || die "release $tag does not exist - run create-prerelease first"
    gh release edit "$tag" --prerelease=false --latest "${title_args[@]+"${title_args[@]}"}"
    upload_assets required
    ;;
  append)
    release_exists || die "release $tag does not exist - nothing to append to"
    [ "${#notes_args[@]}" -eq 2 ] || die "append needs NOTES_FILE pointing at an existing section file"
    title="${APPEND_TITLE:-Update}"
    # Re-running a failed job is the ordinary way an Actions failure is
    # recovered (it is why the asset upload uses --clobber), so append has to be
    # idempotent too: the block is stripped and re-added, never stacked. The
    # marker format and the strip live in scripts/lib/body-section.sh, shared
    # with the release PR body (pr-notes.sh).
    gh release view "$tag" --json body --jq '.body' > "$body_file"
    {
      strip_section_block "$body_file" "$title"
      render_section_block "$title" "$NOTES_FILE"
    } > "$stripped_file"
    gh release edit "$tag" --notes-file "$stripped_file"
    # No upload_assets here, deliberately. `append` records what a store action
    # did (a rollout percentage, a halt) from a job that has no binaries staged:
    # an upload would attach nothing and, worse, regenerate SHA256SUMS over
    # whatever happens to be in $WORKFLOWS_ASSETS_DIR - replacing the checksum file
    # that describes the release's real assets with one computed from an empty
    # or partial directory. append touches the body, nothing else.
    ;;
  *)
    die "unknown mode '$mode' (create-prerelease|promote|latest|append)"
    ;;
esac

log "release $tag: $mode done"
gh_output tag "$tag"
gh_output url "$(gh release view "$tag" --json url --jq '.url')"
