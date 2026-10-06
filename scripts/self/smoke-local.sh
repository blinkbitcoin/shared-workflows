#!/usr/bin/env bash
# Run .github/workflows/self-smoke-local.yml on this machine with nektos/act:
# the Linux half of a consumer's internal release (Prepare, and with --android
# the Android build) against the workflows in this checkout. See the comment
# at the top of that workflow for what act can and cannot show.
#
# Usage: smoke-local.sh [--android]
# Env:   WORKFLOWS_SMOKE_REPOSITORY / WORKFLOWS_SMOKE_REF - the consumer
#        (default: the template at main)
#        WORKFLOWS_ACT_IMAGE - runner image for ubuntu-latest (pulled once per
#        platform and kept as smoke-local-runner:<platform>-<hash>; remove
#        that image to refresh it)
#        WORKFLOWS_SMOKE_ACCEPT_ANDROID_LICENSES=1 - agree to the Android SDK
#        licences without the prompt (--android, first run only)
#        WORKFLOWS_ACT_ANDROID_SDK_VOLUME - the Docker volume holding the
#        Android SDK (default smoke-local-android-sdk)
#        WORKFLOWS_ACT_CACHE - where the substitute artifact actions and the
#        per-checkout run locks are kept
#        WORKFLOWS_ACT_SERVER_ADDR - where act's artifact and cache servers
#        listen, and the address the job reaches them on (default 127.0.0.1,
#        see below)
#        WORKFLOWS_ACT_ARTIFACT_PORT - the artifact server's port (default: the
#        first free one from a port derived from this checkout's path)
#        WORKFLOWS_ACT_ARGS  - extra arguments appended to act (e.g. -v)
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
require_cmd git act docker gh cksum

android=false
for arg in "$@"; do
  case "$arg" in
    --android) android=true ;;
    *) die "unknown argument: $arg (usage: smoke-local.sh [--android])" ;;
  esac
done

workflow=.github/workflows/self-smoke-local.yml
[ -f "$workflow" ] || die "run from the repository root: $workflow not found in $PWD"

docker info >/dev/null 2>&1 || die "docker is not running - act needs a Docker daemon"

# build-prepare checks out this repository into .workflows *from GitHub*, at the
# ref act derives from the local HEAD, and actions/checkout then verifies that
# the ref still points at the local sha. A branch that is not pushed, or has
# moved since, fails inside the job with a confusing "does not point to the
# expected commit"; a detached HEAD resolves to whatever tag sits on it. Say
# so here instead.
branch="$(git rev-parse --abbrev-ref HEAD)"
[ "$branch" != "HEAD" ] || die "detached HEAD - check out a branch and push it first"
local_sha="$(git rev-parse HEAD)"
remote_sha="$(git ls-remote origin "refs/heads/$branch" | cut -f1)"
[ -n "$remote_sha" ] || die "branch '$branch' is not on origin - push it first (act clones this repository from GitHub at the local HEAD)"
[ "$remote_sha" = "$local_sha" ] || die "branch '$branch' on origin is at ${remote_sha:0:7}, HEAD is ${local_sha:0:7} - push first"

# arm64 hosts run Prepare on the arm64 image natively. The Android leg is
# amd64 everywhere, emulated on an arm64 host: Google publishes the Linux
# build-tools (aapt2) and NDK for x86_64 only, and GitHub's runner is x86_64.
case "$(uname -m)" in
  arm64 | aarch64) platform=linux/arm64 ;;
  *) platform=linux/amd64 ;;
esac
[ "$android" = false ] || platform=linux/amd64

# The licences of the Android SDK are the developer's to accept, once per
# machine: the SDK lives in a Docker volume every later run reuses.
consent() {
  [ "${WORKFLOWS_SMOKE_ACCEPT_ANDROID_LICENSES:-0}" = 1 ] && return 0
  if [ -t 0 ]; then
    local answer
    printf '%s [y/N] ' "$1" >&2
    read -r answer || answer=""
    case "$answer" in y | Y | yes | YES) return 0 ;; esac
  fi
  die "not confirmed: $1. Answer y in a terminal, or set WORKFLOWS_SMOKE_ACCEPT_ANDROID_LICENSES=1 to agree non-interactively."
}
android_args=()
# The JDK sdkmanager runs in, as act's runner image has no Java of its own:
# pinned by the digest of its multi-platform index.
jdk_image="eclipse-temurin:21-jdk@sha256:3e3c176ffed168beb42c607be9bc1639b466cf00261a0fb04425562c9d0c5c2b"
if [ "$android" = true ]; then
  sdk_volume="${WORKFLOWS_ACT_ANDROID_SDK_VOLUME:-smoke-local-android-sdk}"
  sdk_dir=/opt/android-sdk
  if ! docker run --rm -v "$sdk_volume:$sdk_dir" "$jdk_image" \
    test -f "$sdk_dir/licenses/android-sdk-license" -a -x "$sdk_dir/cmdline-tools/latest/bin/sdkmanager" >/dev/null 2>&1; then
    consent "Install the Android SDK into the Docker volume $sdk_volume, accepting its licences (https://developer.android.com/studio/terms)"
    log "act smoke: provisioning the Android SDK in $sdk_volume (once; about 2 GB)"
    docker run --rm -e "ANDROID_HOME=$sdk_dir" -v "$sdk_volume:$sdk_dir" \
      -v "$PWD/scripts:/workflows-scripts:ro" "$jdk_image" \
      bash /workflows-scripts/self/smoke-android-sdk.sh ||
      die "could not provision the Android SDK in $sdk_volume (docker volume rm $sdk_volume starts it over)"
  fi
  android_args=(
    --container-options "-v $sdk_volume:$sdk_dir"
    --env "ANDROID_HOME=$sdk_dir"
    --env "ANDROID_SDK_ROOT=$sdk_dir"
  )
fi

cache="${WORKFLOWS_ACT_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/smoke-local}"
# One number per checkout: it names the run lock and places the artifact port.
checkout_id="$(printf '%s' "$PWD" | cksum | cut -d' ' -f1)"

# act names every container and volume after the job and a hash of the
# checkout's path, and keeps them when a job fails (unless --rm) or when act is
# killed: a Prepare container once stayed up for six days. Two checkouts never
# share a name; two runs from one checkout do, so the second is refused while
# the first is alive, and a lock whose process is gone means its containers are
# leftovers, removed before this run starts.
act_leftovers() {
  local names name dir
  names="$(docker ps -a --filter 'name=^act-' --format '{{.Names}}')" || return 0
  for name in $names; do
    dir="$(docker inspect --format '{{.Config.WorkingDir}}' "$name" 2>/dev/null)" || continue
    [ "$dir" = "$PWD" ] || continue
    log "act smoke: removing container $name and its volumes"
    docker rm -f "$name" >/dev/null 2>&1 || true
    docker volume rm -f "$name" "$name-env" >/dev/null 2>&1 || true
  done
}
mkdir -p "$cache/runs"
lock="$cache/runs/$checkout_id.pid"
if [ -f "$lock" ]; then
  holder="$(cat "$lock")"
  if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then
    die "a smoke run from this checkout is already running (pid $holder) - wait for it, or run from another worktree"
  fi
fi
act_leftovers
printf '%s\n' "$$" > "$lock"

artifacts="$(mktemp -d "${TMPDIR:-/tmp}/smoke-local-artifacts.XXXXXX")"
# act runs every workflow as run 1. upload-artifact first lists the run's
# artifacts, and act's server panics on a run directory that does not exist yet
# (a Go stack trace in the log, then an empty list) - harmless, and alarming.
mkdir "$artifacts/1"
cleanup() {
  act_leftovers
  rm -rf "$artifacts"
  rm -f "$lock"
}
trap cleanup EXIT
# Ctrl-C reaches act too (same process group); it stops its jobs and returns,
# and only then does this exit, through the EXIT trap.
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# act pulls the image on every run by default, a registry round trip per job.
# Pulled once here, per platform, and act is told not to. A tag holds one
# platform at a time, so each platform's pull is kept under a tag of its own:
# an Android run pulling amd64 would otherwise hand the next arm64 Prepare an
# emulated image.
image="${WORKFLOWS_ACT_IMAGE:-catthehacker/ubuntu:act-latest}"
runner="smoke-local-runner:${platform#linux/}-$(printf '%s' "$image" | cksum | cut -d' ' -f1)"
if ! docker image inspect "$runner" >/dev/null 2>&1; then
  log "act smoke: pulling $image for $platform as $runner (once; docker image rm $runner to refresh)"
  docker pull --platform "$platform" "$image" >/dev/null || die "could not pull $image for $platform"
  docker tag "$image" "$runner" || die "could not tag $image as $runner"
fi

# act's artifact server speaks the v4 artifact protocol and rejects the
# `mime_type` field upload-artifact@v7 sends (nektos/act #6022, #6114; no
# release carries a fix). The workflows keep v7/v8 - that is what runs on
# GitHub - and act is told to run the last v4 of each in their place, from a
# pinned checkout made on first use.
substitute() {
  local action="$1" tag="$2" dir
  dir="$cache/$action-$tag"
  if [ ! -d "$dir" ]; then
    log "act smoke: fetching actions/$action@$tag into $dir (once)"
    # `|| die`, not `set -e`: this runs inside `$(...)`, which `set -e` does
    # not reach, and a half-cloned directory would make every later run skip
    # the fetch.
    git -c advice.detachedHead=false clone -q --depth 1 --branch "$tag" \
      "https://github.com/actions/$action" "$dir" ||
      { rm -rf "$dir"; die "could not fetch actions/$action@$tag into $dir"; }
  fi
  printf '%s\n' "$dir"
}
upload_v4="$(substitute upload-artifact v4.6.2)"
download_v4="$(substitute download-artifact v4.3.0)"

# act's artifact and cache servers each listen on, and hand the job, one
# address: by default the host's default-route address. Behind a VPN that is
# the tunnel's own address, which nothing reaches - the build-info upload timed
# out five times against 10.2.0.2 on a Mac with a VPN up, and every
# actions/cache restore and save (mise's tools, the gems, the pnpm store,
# Gradle) timed out with it, so each run installed everything from nothing.
# The job runs on the host network (act's default), where loopback is the
# host's own on Linux and forwarded to the Mac's under OrbStack, so the default
# here is 127.0.0.1. A Docker whose host network cannot reach the host's
# loopback takes an address that it can, through the variable.
server_addr="${WORKFLOWS_ACT_SERVER_ADDR:-127.0.0.1}"

# The cache server takes a free port by itself (act's default, port 0). The
# artifact server's default is a fixed 34567, and a second run anywhere on the
# machine died on "bind: address already in use". Each checkout starts from
# its own port in 34567-35566 and takes the first free one from there, so two
# worktrees starting at once do not race for the same one.
port_in_use() { (exec 3<>"/dev/tcp/$server_addr/$1") 2>/dev/null; }
if [ -n "${WORKFLOWS_ACT_ARTIFACT_PORT:-}" ]; then
  artifact_port="$WORKFLOWS_ACT_ARTIFACT_PORT"
  ! port_in_use "$artifact_port" || die "artifact server port $artifact_port on $server_addr is in use - pick another WORKFLOWS_ACT_ARTIFACT_PORT"
else
  artifact_port=""
  first=$((34567 + checkout_id % 1000))
  for ((port = first; port < first + 50; port++)); do
    if ! port_in_use "$port"; then
      artifact_port="$port"
      break
    fi
  done
  [ -n "$artifact_port" ] || die "no free artifact server port in $first-$((first + 49)) on $server_addr - set WORKFLOWS_ACT_ARTIFACT_PORT"
fi

# The token is only read by the two checkouts (both public repositories) and,
# with `reserve-tag: false`, never writes anything.
token="$(gh auth token)"

log "act smoke: branch $branch at ${local_sha:0:7}, android=$android, artifacts at $server_addr:$artifact_port, cache at $server_addr"
# Not `exec`: the EXIT trap has to run after act returns.
# shellcheck disable=SC2086 # WORKFLOWS_ACT_ARGS is a deliberate word-split
act workflow_dispatch \
  -W "$workflow" \
  -P "ubuntu-latest=$runner" \
  --container-architecture "$platform" \
  ${android_args[@]+"${android_args[@]}"} \
  --pull=false \
  --rm \
  --artifact-server-path "$artifacts" \
  --artifact-server-addr "$server_addr" \
  --artifact-server-port "$artifact_port" \
  --cache-server-addr "$server_addr" \
  --local-repository "actions/upload-artifact@v7=$upload_v4" \
  --local-repository "actions/download-artifact@v8=$download_v4" \
  -s GITHUB_TOKEN="$token" \
  --input "repository=${WORKFLOWS_SMOKE_REPOSITORY:-blinkbitcoin/react-native-mobile-template}" \
  --input "ref=${WORKFLOWS_SMOKE_REF:-main}" \
  --input "android=$android" \
  ${WORKFLOWS_ACT_ARGS:-}
