#!/usr/bin/env bats
load test_helper

# self-smoke-local.yml is excluded from workflow-shape.bats with the other
# self-* workflows, so its own invariants live here: it is act's entry point
# into the release workflows and must never reach GitHub or create anything.

WF="$REPO_ROOT/.github/workflows/self-smoke-local.yml"
SCRIPT="$REPO_ROOT/scripts/self/smoke-local.sh"

@test "the smoke workflow is workflow_dispatch only, so GitHub never runs it" {
  [ "$(yq -r '.on | keys | join(",")' "$WF")" = "workflow_dispatch" ] \
    || fail "self-smoke-local.yml has triggers other than workflow_dispatch: $(yq -r '.on | keys' "$WF")"
}

@test "every job calls a workflow from this checkout, never @v0" {
  bad=$(yq -r '[.jobs[].uses | select(test("^\\./\\.github/workflows/") | not)] | join(", ")' "$WF")
  [ -z "$bad" ] || fail "self-smoke-local.yml calls a workflow outside this checkout: $bad"
}

@test "the smoke never reserves a tag and never waits on a green gate" {
  [ "$(yq -r '.jobs.prepare.with."reserve-tag"' "$WF")" = "false" ] \
    || fail "reserve-tag must be false: the token act runs with is the developer's own"
  [ "$(yq -r '.jobs.prepare.with."require-green-workflow"' "$WF")" = "" ] \
    || fail "require-green-workflow must be empty: nothing has run for a local commit"
}

@test "the Android build is opt-in and unsigned" {
  [ "$(yq -r '.jobs."build-android".if' "$WF")" = '${{ inputs.android }}' ] \
    || fail "build-android is not gated on inputs.android"
  [ "$(yq -r '.jobs."build-android".with."android-signing-enabled"' "$WF")" = "false" ] \
    || fail "build-android must run unsigned"
}

@test "the Android build writes act's Gradle cache, so the next run builds warm" {
  # build-android writes the cache only when github.ref is default-branch;
  # under act github.ref is the local branch, never refs/heads/main.
  [ "$(yq -r '.jobs."build-android".with."default-branch"' "$WF")" = '${{ github.ref }}' ] \
    || fail "build-android's default-branch is not github.ref: setup-gradle would run read-only and every run would build cold"
}

@test "no job sets a macOS runner: the smoke is the Linux half only" {
  ! grep -qE 'macos' "$WF" || fail "self-smoke-local.yml mentions a macOS runner"
}

# --- the entry script -------------------------------------------------------

setup() {
  # A scratch clone with a bare origin, and fake act/docker/gh on PATH that
  # record what they were asked, so the script's guards and the arguments it
  # hands act can be checked without Docker.
  origin="$BATS_TEST_TMPDIR/origin.git"
  work="$BATS_TEST_TMPDIR/work"
  git init -q --bare "$origin"
  git clone -q "$origin" "$work" 2>/dev/null || git init -q "$work"
  git -C "$work" remote get-url origin >/dev/null 2>&1 || git -C "$work" remote add origin "$origin"
  git -C "$work" config user.email test@example.com
  git -C "$work" config user.name test
  git -C "$work" switch -qc feature 2>/dev/null || git -C "$work" checkout -qb feature
  git -C "$work" commit -q --allow-empty -m "feat: one"
  mkdir -p "$work/.github/workflows"
  # Every workflow, not only the smoke's: the script reads the refs the
  # artifact steps name from all of them, to substitute each one.
  cp "$REPO_ROOT"/.github/workflows/*.yml "$work/.github/workflows/"
  bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  # act records its arguments and the token its environment hands it and,
  # when FAKE_ACT_EXIT is set, fails with it.
  cat > "$bin/act" <<STUB
#!/usr/bin/env bash
printf '%s\\n' "\$@" > "$BATS_TEST_TMPDIR/act.args"
printf '%s' "\${GITHUB_TOKEN-}" > "$BATS_TEST_TMPDIR/act.token"
exit "\${FAKE_ACT_EXIT:-0}"
STUB
  # docker records every call. Its containers are the lines of
  # \$BATS_TEST_TMPDIR/containers, "name working-directory"; the image is
  # present unless FAKE_DOCKER_NO_IMAGE is set. Of \`docker run\`, the check
  # for a provisioned Android SDK passes when FAKE_SDK_READY is set, and the
  # provisioning exits with FAKE_SDK_PROVISION_EXIT.
  cat > "$bin/docker" <<STUB
#!/usr/bin/env bash
printf '%s\\n' "\$*" >> "$BATS_TEST_TMPDIR/docker.calls"
list="$BATS_TEST_TMPDIR/containers"
case "\$1 \${2:-}" in
  "ps -a") [ -f "\$list" ] && cut -d' ' -f1 "\$list"; exit 0 ;;
  "inspect --format") grep "^\${4} " "\$list" | cut -d' ' -f2-; exit 0 ;;
  "image inspect") [ -z "\${FAKE_DOCKER_NO_IMAGE:-}" ]; exit ;;
esac
if [ "\$1" = run ]; then
  case "\$*" in
    *" test -f "*) [ -n "\${FAKE_SDK_READY:-}" ]; exit ;;
    *smoke-android-sdk.sh*) exit "\${FAKE_SDK_PROVISION_EXIT:-0}" ;;
  esac
fi
exit 0
STUB
  printf '#!/usr/bin/env bash\necho fake-token\n' > "$bin/gh"
  chmod +x "$bin/act" "$bin/docker" "$bin/gh"
  export PATH="$bin:$PATH"
  # The substitute artifact actions are "already fetched", so no clone runs.
  export WORKFLOWS_ACT_CACHE="$BATS_TEST_TMPDIR/cache"
  mkdir -p "$WORKFLOWS_ACT_CACHE/upload-artifact-v4.6.2" "$WORKFLOWS_ACT_CACHE/download-artifact-v4.3.0"
}

# The platform a run without --android uses: the host's own.
host_platform() { case "$(uname -m)" in arm64 | aarch64) echo linux/arm64 ;; *) echo linux/amd64 ;; esac; }
# The local tag the script keeps the runner image under, for a platform.
runner_tag() { printf 'smoke-local-runner:%s-%s' "${1#linux/}" "$(printf '%s' "${2:-catthehacker/ubuntu:act-latest}" | cksum | cut -d' ' -f1)"; }
# The JDK image the script pins, read from it.
jdk_image() { sed -n 's/^jdk_image="\(.*\)"$/\1/p' "$SCRIPT"; }
# The value act was given for a flag that takes one.
act_arg() { grep -A1 -x -- "$1" "$BATS_TEST_TMPDIR/act.args" | tail -1; }
# The run lock of the scratch checkout, named as the script names it.
lock_file() { printf '%s/runs/%s.pid' "$WORKFLOWS_ACT_CACHE" "$(cd "$work" && printf '%s' "$PWD" | cksum | cut -d' ' -f1)"; }
# Hold TCP ports on 127.0.0.1 open until the test ends, all in one process;
# returns once the last one listens.
hold_port() {
  node -e 'for (const p of process.argv.slice(1)) require("net").createServer().listen(Number(p), "127.0.0.1")' "$@" &
  local holder=$! last="${*: -1}"
  background "$holder"
  wait_for 60 "port(s) $* to be held" accepts "$last" || return
}
# Something accepts a connection on 127.0.0.1:PORT.
accepts() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }
# Every helper process a test starts is stopped by teardown, quietly.
background() { disown "$1"; echo "$1" >> "$BATS_TEST_TMPDIR/background"; }
teardown() {
  [ -f "$BATS_TEST_TMPDIR/background" ] || return 0
  xargs kill 2>/dev/null < "$BATS_TEST_TMPDIR/background" || true
}

@test "refuses a branch that is not on origin, and says to push" {
  cd "$work"
  run bash "$SCRIPT"
  [ "$status" -ne 0 ] || fail "the run was not refused: $output"
  contains "$output" "push it first" || fail "output: $output"
  [ ! -f "$BATS_TEST_TMPDIR/act.args" ] || fail "act was run anyway"
}

@test "refuses when origin is behind the local HEAD" {
  cd "$work"
  git push -q origin feature
  git commit -q --allow-empty -m "feat: two"
  run bash "$SCRIPT"
  [ "$status" -ne 0 ] || fail "the run was not refused: $output"
  contains "$output" "push first" || fail "output: $output"
}

@test "refuses a detached HEAD" {
  cd "$work"
  git push -q origin feature
  git checkout -q --detach
  run bash "$SCRIPT"
  [ "$status" -ne 0 ] || fail "the run was not refused: $output"
  contains "$output" "detached HEAD" || fail "output: $output"
}

@test "runs act on the smoke workflow with the pinned image, its servers on loopback and the token" {
  cd "$work"
  git push -q origin feature
  run bash "$SCRIPT"
  [ "$status" -eq 0 ] || fail "output: $output"
  args="$(cat "$BATS_TEST_TMPDIR/act.args")"
  contains "$args" "workflow_dispatch" || fail "args: $args"
  contains "$args" ".github/workflows/self-smoke-local.yml" || fail "args: $args"
  # The local, per-platform tag of the pinned image, on the host's platform.
  contains "$args" "ubuntu-latest=$(runner_tag "$(host_platform)")" || fail "args: $args"
  [ "$(act_arg --container-architecture)" = "$(host_platform)" ] || fail "args: $args"
  ! contains "$args" "ANDROID_HOME" || fail "Prepare alone was given an Android SDK: $args"
  contains "$args" "--artifact-server-path" || fail "args: $args"
  # The run directory exists before the first upload lists it (act's server
  # panics on a missing one). The fake act ran while it was there; it is gone now.
  printf '#!/usr/bin/env bash\n[ -d "$(grep -A1 -x -- --artifact-server-path <<<"$(printf "%%s\\n" "$@")" | tail -1)/1" ] || exit 7\n' > "$bin/act"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ] || fail "the artifact server's run directory was missing when act started: $output"
  # Loopback, not act's default-route guess: behind a VPN that is a tunnel
  # address the job cannot reach, and every upload - and every cache restore
  # and save - times out.
  [ "$(act_arg --artifact-server-addr)" = "127.0.0.1" ] || fail "the artifact server is not on 127.0.0.1: $args"
  [ "$(act_arg --cache-server-addr)" = "127.0.0.1" ] || fail "the cache server is not on 127.0.0.1: $args"
  # The token goes through act's environment, never an argument, which any
  # local user could read in `ps` for the whole run.
  [ "$(act_arg -s)" = "GITHUB_TOKEN" ] || fail "act is not asked for GITHUB_TOKEN by name: $args"
  [ "$(cat "$BATS_TEST_TMPDIR/act.token")" = "fake-token" ] || fail "act did not get the token in its environment"
  ! contains "$args" "fake-token" || fail "the token is on act's command line: $args"
  contains "$args" "android=false" || fail "args: $args"
  # act's artifact server cannot take upload-artifact@v7 / download-artifact@v8
  # (nektos/act #6022): both are run as their last v4 from the cache.
  contains "$args" "actions/upload-artifact@v7=$WORKFLOWS_ACT_CACHE/upload-artifact-v4.6.2" || fail "args: $args"
  contains "$args" "actions/download-artifact@v8=$WORKFLOWS_ACT_CACHE/download-artifact-v4.3.0" || fail "args: $args"
  # build-android pins both by commit SHA (the signing workflows' rule), and
  # act matches the exact ref: each pinned SHA gets the same substitute.
  upload_ref="$(grep -ohE 'actions/upload-artifact@[0-9a-f]{40}' "$REPO_ROOT/.github/workflows/build-android.yml" | head -1)"
  download_ref="$(grep -ohE 'actions/download-artifact@[0-9a-f]{40}' "$REPO_ROOT/.github/workflows/build-android.yml" | head -1)"
  [ -n "$upload_ref" ] || fail "build-android.yml no longer pins actions/upload-artifact by SHA"
  [ -n "$download_ref" ] || fail "build-android.yml no longer pins actions/download-artifact by SHA"
  contains "$args" "$upload_ref=$WORKFLOWS_ACT_CACHE/upload-artifact-v4.6.2" || fail "the SHA-pinned upload is not substituted: $args"
  contains "$args" "$download_ref=$WORKFLOWS_ACT_CACHE/download-artifact-v4.3.0" || fail "the SHA-pinned download is not substituted: $args"
  contains "$args" "repository=blinkbitcoin/react-native-mobile-template" || fail "args: $args"
}

@test "WORKFLOWS_ACT_SERVER_ADDR moves both servers, and the log says where they are" {
  cd "$work"
  git push -q origin feature
  WORKFLOWS_ACT_SERVER_ADDR=127.0.0.2 run bash "$SCRIPT"
  [ "$status" -eq 0 ] || fail "output: $output"
  [ "$(act_arg --artifact-server-addr)" = "127.0.0.2" ] || fail "the override did not reach the artifact server: $(cat "$BATS_TEST_TMPDIR/act.args")"
  [ "$(act_arg --cache-server-addr)" = "127.0.0.2" ] || fail "the override did not reach the cache server: $(cat "$BATS_TEST_TMPDIR/act.args")"
  contains "$output" "artifacts at 127.0.0.2:" || fail "the address was not logged: $output"
}

@test "the artifact port is derived from the checkout, and a port in use is skipped" {
  cd "$work"
  git push -q origin feature
  first=$((34567 + $(printf '%s' "$PWD" | cksum | cut -d' ' -f1) % 1000))
  run bash "$SCRIPT"
  [ "$status" -eq 0 ] || fail "output: $output"
  port="$(act_arg --artifact-server-port)"
  # Another test, or a real run, may hold a port in the range: the first free
  # one from $first is taken, never past the 50 probed.
  [ "$port" -ge "$first" ] && [ "$port" -lt $((first + 50)) ] || fail "port $port is not in $first-$((first + 49))"
  contains "$output" "artifacts at 127.0.0.1:$port" || fail "the port was not logged: $output"
  hold_port "$port"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ] || fail "output: $output"
  next="$(act_arg --artifact-server-port)"
  [ "$next" != "$port" ] || fail "the run took port $port, which is in use"
  [ "$next" -gt "$port" ] && [ "$next" -lt $((first + 50)) ] || fail "port $next is not the next free one after $port"
}

@test "WORKFLOWS_ACT_ARTIFACT_PORT picks the port, and one in use is refused before act runs" {
  cd "$work"
  git push -q origin feature
  WORKFLOWS_ACT_ARTIFACT_PORT=40123 run bash "$SCRIPT"
  [ "$status" -eq 0 ] || fail "output: $output"
  [ "$(act_arg --artifact-server-port)" = "40123" ] || fail "args: $(cat "$BATS_TEST_TMPDIR/act.args")"
  rm "$BATS_TEST_TMPDIR/act.args"
  hold_port 40124
  WORKFLOWS_ACT_ARTIFACT_PORT=40124 run bash "$SCRIPT"
  [ "$status" -ne 0 ] || fail "a busy port was accepted: $output"
  contains "$output" "40124 on 127.0.0.1 is in use" || fail "output: $output"
  [ ! -f "$BATS_TEST_TMPDIR/act.args" ] || fail "act was run anyway"
}

@test "no free port in the probed range is a clear failure" {
  cd "$work"
  git push -q origin feature
  # bash's /dev/tcp cannot be faked, so all 50 probed ports are really held.
  first=$((34567 + $(printf '%s' "$PWD" | cksum | cut -d' ' -f1) % 1000))
  hold_port $(seq "$first" $((first + 49)))
  run bash "$SCRIPT"
  [ "$status" -ne 0 ] || fail "the run went ahead without a port: $output"
  contains "$output" "no free artifact server port in $first-$((first + 49))" || fail "output: $output"
}

@test "the image is pulled once per platform when it is missing, kept under its own tag, and act never pulls it" {
  cd "$work"
  git push -q origin feature
  run bash "$SCRIPT"
  [ "$status" -eq 0 ] || fail "output: $output"
  ! grep -q '^pull ' "$BATS_TEST_TMPDIR/docker.calls" || fail "a present image was pulled again"
  grep -qx "image inspect $(runner_tag "$(host_platform)")" "$BATS_TEST_TMPDIR/docker.calls" ||
    fail "the per-platform tag was not what was looked for: $(cat "$BATS_TEST_TMPDIR/docker.calls")"
  grep -qx -- '--pull=false' "$BATS_TEST_TMPDIR/act.args" || fail "act still pulls on every run: $(cat "$BATS_TEST_TMPDIR/act.args")"
  FAKE_DOCKER_NO_IMAGE=1 run bash "$SCRIPT"
  [ "$status" -eq 0 ] || fail "output: $output"
  grep -qx "pull --platform $(host_platform) catthehacker/ubuntu:act-latest" "$BATS_TEST_TMPDIR/docker.calls" ||
    fail "a missing image was not pulled for the platform: $(cat "$BATS_TEST_TMPDIR/docker.calls")"
  grep -qx "tag catthehacker/ubuntu:act-latest $(runner_tag "$(host_platform)")" "$BATS_TEST_TMPDIR/docker.calls" ||
    fail "the pull was not kept under its platform's tag: $(cat "$BATS_TEST_TMPDIR/docker.calls")"
  # Another image gets a tag of its own, not the pinned image's.
  : > "$BATS_TEST_TMPDIR/docker.calls"
  WORKFLOWS_ACT_IMAGE=example/runner:1 FAKE_DOCKER_NO_IMAGE=1 run bash "$SCRIPT"
  [ "$status" -eq 0 ] || fail "output: $output"
  grep -qx "tag example/runner:1 $(runner_tag "$(host_platform)" example/runner:1)" "$BATS_TEST_TMPDIR/docker.calls" ||
    fail "WORKFLOWS_ACT_IMAGE shared the pinned image's tag: $(cat "$BATS_TEST_TMPDIR/docker.calls")"
}

@test "a failed pull stops the smoke before act runs" {
  cd "$work"
  git push -q origin feature
  printf '#!/usr/bin/env bash\ncase "$1 $2" in "image inspect") exit 1 ;; "pull "*) exit 1 ;; esac\nexit 0\n' > "$bin/docker"
  run bash "$SCRIPT"
  [ "$status" -ne 0 ] || fail "output: $output"
  contains "$output" "could not pull catthehacker/ubuntu:act-latest for $(host_platform)" || fail "output: $output"
  [ ! -f "$BATS_TEST_TMPDIR/act.args" ] || fail "act was run anyway"
}

@test "a pull that cannot be tagged stops the smoke before act runs" {
  cd "$work"
  git push -q origin feature
  printf '#!/usr/bin/env bash\ncase "$1 $2" in "image inspect") exit 1 ;; "tag "*) exit 1 ;; esac\nexit 0\n' > "$bin/docker"
  run bash "$SCRIPT"
  [ "$status" -ne 0 ] || fail "output: $output"
  contains "$output" "could not tag catthehacker/ubuntu:act-latest as smoke-local-runner:" || fail "output: $output"
  [ ! -f "$BATS_TEST_TMPDIR/act.args" ] || fail "act was run anyway"
}

@test "this checkout's act containers and volumes are removed when the run ends, pass or fail, and no other checkout's" {
  cd "$work"
  git push -q origin feature
  printf 'act-Prepare-mine %s\nact-Prepare-theirs /somewhere/else\n' "$PWD" > "$BATS_TEST_TMPDIR/containers"
  for code in 0 1; do
    : > "$BATS_TEST_TMPDIR/docker.calls"
    FAKE_ACT_EXIT=$code run bash "$SCRIPT"
    [ "$status" -eq "$code" ] || fail "act's status $code was not passed on: $status, $output"
    calls="$(cat "$BATS_TEST_TMPDIR/docker.calls")"
    # Twice: once as leftovers before the run (none were running), once after.
    [ "$(grep -cx 'rm -f act-Prepare-mine' <<<"$calls")" -eq 2 ] || fail "act=$code: the container was not removed before and after: $calls"
    grep -qx 'volume rm -f act-Prepare-mine act-Prepare-mine-env' <<<"$calls" || fail "act=$code: its volumes were left: $calls"
    ! grep -qE '^(rm|volume rm) .*theirs' <<<"$calls" || fail "act=$code: another checkout's container was removed: $calls"
    [ ! -e "$(lock_file)" ] || fail "act=$code: the run lock was left behind"
  done
  # act itself is also told to clean up after a failed job.
  grep -qx -- '--rm' "$BATS_TEST_TMPDIR/act.args" || fail "args: $(cat "$BATS_TEST_TMPDIR/act.args")"
}

@test "a second run from the same checkout is refused while the first is alive, and leaves its containers alone" {
  cd "$work"
  git push -q origin feature
  printf 'act-Prepare-mine %s\n' "$PWD" > "$BATS_TEST_TMPDIR/containers"
  mkdir -p "$(dirname "$(lock_file)")"
  sleep 300 &
  holder=$!
  background "$holder"
  echo "$holder" > "$(lock_file)"
  run bash "$SCRIPT"
  [ "$status" -ne 0 ] || fail "output: $output"
  contains "$output" "already running (pid $holder)" || fail "output: $output"
  [ ! -f "$BATS_TEST_TMPDIR/act.args" ] || fail "act was run anyway"
  ! grep -q '^rm ' "$BATS_TEST_TMPDIR/docker.calls" || fail "the live run's container was removed: $(cat "$BATS_TEST_TMPDIR/docker.calls")"
  [ "$(cat "$(lock_file)")" = "$holder" ] || fail "the live run's lock was taken over"
}

@test "a lock left by a run that is gone does not block, and its containers are cleared first" {
  cd "$work"
  git push -q origin feature
  printf 'act-Prepare-mine %s\n' "$PWD" > "$BATS_TEST_TMPDIR/containers"
  mkdir -p "$(dirname "$(lock_file)")"
  # A pid that has exited: a run killed with SIGKILL leaves exactly this.
  bash -c 'exit 0' & wait $!
  echo $! > "$(lock_file)"
  # act checks the container is gone before it starts.
  cat > "$bin/act" <<STUB
#!/usr/bin/env bash
grep -qx 'rm -f act-Prepare-mine' "$BATS_TEST_TMPDIR/docker.calls" || { echo "leftover still there" >&2; exit 9; }
printf '%s\\n' "\$@" > "$BATS_TEST_TMPDIR/act.args"
STUB
  run bash "$SCRIPT"
  [ "$status" -eq 0 ] || fail "output: $output"
  contains "$output" "removing container act-Prepare-mine" || fail "output: $output"
}

@test "an interrupted run still removes its containers and its lock" {
  cd "$work"
  git push -q origin feature
  printf 'act-Prepare-mine %s\n' "$PWD" > "$BATS_TEST_TMPDIR/containers"
  # act that marks that it started, then stops on a signal the way act does:
  # it ends its jobs and exits non-zero.
  cat > "$bin/act" <<STUB
#!/usr/bin/env bash
trap 'kill \$! 2>/dev/null; exit 1' INT TERM HUP
touch "$BATS_TEST_TMPDIR/act.started"
sleep 30 & wait
STUB
  for signal in INT TERM HUP; do
    rm -f "$BATS_TEST_TMPDIR/act.started"
    : > "$BATS_TEST_TMPDIR/docker.calls"
    # A job started with & ignores SIGINT, and bash cannot trap a signal it was
    # started ignoring: perl puts the default back, as a terminal has it.
    perl -e '$SIG{INT} = "DEFAULT"; exec @ARGV' bash "$SCRIPT" 2>/dev/null &
    pid=$!
    # The script reaches act in under a second on a quiet machine, but in 5 to
    # 9 seconds beside a parallel bats suite, as under `make check`, which a
    # 10-second bound failed. The wait returns once act has started, so only a
    # run that is really broken waits out the 60 seconds.
    wait_for 60 "$signal: act to start" test -f "$BATS_TEST_TMPDIR/act.started"
    [ -f "$BATS_TEST_TMPDIR/act.started" ] || fail "$signal: act never started"
    # A terminal's Ctrl-C or hang-up reaches the script and act together.
    kill -"$signal" "$pid" "$(pgrep -P "$pid")"
    status=0; wait "$pid" || status=$?
    [ "$status" -ne 0 ] || fail "$signal: an interrupted run reported success"
    [ "$(grep -cx 'rm -f act-Prepare-mine' "$BATS_TEST_TMPDIR/docker.calls")" -eq 2 ] ||
      fail "$signal: the container was not removed on the way out: $(cat "$BATS_TEST_TMPDIR/docker.calls")"
    [ ! -e "$(lock_file)" ] || fail "$signal: the run lock was left behind"
  done
}

@test "a failed fetch of a substitute action stops the smoke, and leaves no half-cloned cache" {
  cd "$work"
  git push -q origin feature
  rm -rf "$WORKFLOWS_ACT_CACHE/upload-artifact-v4.6.2"
  # git that fails a clone from GitHub part-way, after creating the directory,
  # and is the real git for everything else.
  local real_git
  real_git="$(command -v git)"
  cat > "$bin/git" <<STUB
#!/usr/bin/env bash
case "\$*" in
  *clone*https://github.com/actions/*) mkdir -p "\${@: -1}/.git"; echo "fatal: unable to access" >&2; exit 128 ;;
esac
exec "$real_git" "\$@"
STUB
  chmod +x "$bin/git"
  run bash "$SCRIPT"
  [ "$status" -ne 0 ] || fail "the smoke carried on without its action: $output"
  [ ! -f "$BATS_TEST_TMPDIR/act.args" ] || fail "act was run anyway"
  [ ! -e "$WORKFLOWS_ACT_CACHE/upload-artifact-v4.6.2" ] ||
    fail "a half-cloned action was left in the cache, so the next run would skip the fetch"
}

@test "--android runs amd64 with the SDK volume mounted, and asks nothing once the SDK is there" {
  cd "$work"
  git push -q origin feature
  FAKE_SDK_READY=1 run bash "$SCRIPT" --android
  [ "$status" -eq 0 ] || fail "output: $output"
  args="$(cat "$BATS_TEST_TMPDIR/act.args")"
  contains "$args" "android=true" || fail "args: $args"
  # amd64 on every host: the Linux build-tools and NDK exist for x86_64 only.
  [ "$(act_arg --container-architecture)" = "linux/amd64" ] || fail "args: $args"
  contains "$args" "ubuntu-latest=$(runner_tag linux/amd64)" || fail "args: $args"
  [ "$(act_arg --container-options)" = "-v smoke-local-android-sdk:/opt/android-sdk" ] || fail "args: $args"
  grep -qx 'ANDROID_HOME=/opt/android-sdk' "$BATS_TEST_TMPDIR/act.args" || fail "args: $args"
  grep -qx 'ANDROID_SDK_ROOT=/opt/android-sdk' "$BATS_TEST_TMPDIR/act.args" || fail "args: $args"
  ! grep -q 'smoke-android-sdk.sh' "$BATS_TEST_TMPDIR/docker.calls" || fail "a provisioned SDK was provisioned again"
  # The check runs in the pinned JDK image, against the volume.
  grep -q "^run --rm --platform linux/amd64 -v smoke-local-android-sdk:/opt/android-sdk $(jdk_image) test -f " "$BATS_TEST_TMPDIR/docker.calls" ||
    fail "the SDK check did not run in the pinned JDK image: $(cat "$BATS_TEST_TMPDIR/docker.calls")"
}

@test "WORKFLOWS_ACT_ANDROID_SDK_VOLUME names the SDK volume" {
  cd "$work"
  git push -q origin feature
  WORKFLOWS_ACT_ANDROID_SDK_VOLUME=my-sdk FAKE_SDK_READY=1 run bash "$SCRIPT" --android
  [ "$status" -eq 0 ] || fail "output: $output"
  [ "$(act_arg --container-options)" = "-v my-sdk:/opt/android-sdk" ] || fail "args: $(cat "$BATS_TEST_TMPDIR/act.args")"
}

@test "without an SDK and with no one to ask, --android is refused before anything is installed or run" {
  cd "$work"
  git push -q origin feature
  run bash "$SCRIPT" --android </dev/null
  [ "$status" -ne 0 ] || fail "output: $output"
  contains "$output" "not confirmed: Install the Android SDK" || fail "output: $output"
  contains "$output" "WORKFLOWS_SMOKE_ACCEPT_ANDROID_LICENSES=1" || fail "the way to agree was not named: $output"
  ! grep -q 'smoke-android-sdk.sh' "$BATS_TEST_TMPDIR/docker.calls" || fail "the SDK was provisioned without consent"
  [ ! -f "$BATS_TEST_TMPDIR/act.args" ] || fail "act was run anyway"
  [ ! -e "$(lock_file)" ] || fail "a refused run left a lock"
}

@test "agreeing through the environment provisions the SDK once, in the JDK image, with this checkout's scripts" {
  cd "$work"
  git push -q origin feature
  WORKFLOWS_SMOKE_ACCEPT_ANDROID_LICENSES=1 run bash "$SCRIPT" --android
  [ "$status" -eq 0 ] || fail "output: $output"
  # amd64: the command-line tools' android binary is x86-64 only.
  grep -qx "run --rm --platform linux/amd64 -e ANDROID_HOME=/opt/android-sdk -v smoke-local-android-sdk:/opt/android-sdk -v $PWD/scripts:/workflows-scripts:ro $(jdk_image) bash /workflows-scripts/self/smoke-android-sdk.sh" \
    "$BATS_TEST_TMPDIR/docker.calls" || fail "provisioning did not run as expected: $(cat "$BATS_TEST_TMPDIR/docker.calls")"
  contains "$output" "provisioning the Android SDK in smoke-local-android-sdk" || fail "output: $output"
  contains "$(cat "$BATS_TEST_TMPDIR/act.args")" "android=true" || fail "act did not run after provisioning"
}

@test "an answer at the terminal decides: y provisions, anything else refuses" {
  cd "$work"
  git push -q origin feature
  # A real terminal on stdin, which [ -t 0 ] needs: python's pty, fed the answer.
  ask() {
    printf '%s\n' "$1" | python3 -c 'import pty, sys; sys.exit(pty.spawn(sys.argv[1:]) >> 8)' bash "$SCRIPT" --android
  }
  run ask y
  [ "$status" -eq 0 ] || fail "y was not taken as agreement: $output"
  contains "$output" "[y/N]" || fail "nothing was asked: $output"
  grep -q 'smoke-android-sdk.sh' "$BATS_TEST_TMPDIR/docker.calls" || fail "y did not provision the SDK"
  : > "$BATS_TEST_TMPDIR/docker.calls"
  rm -f "$BATS_TEST_TMPDIR/act.args"
  run ask n
  [ "$status" -ne 0 ] || fail "n was taken as agreement: $output"
  contains "$output" "not confirmed" || fail "output: $output"
  ! grep -q 'smoke-android-sdk.sh' "$BATS_TEST_TMPDIR/docker.calls" || fail "n provisioned the SDK"
  [ ! -f "$BATS_TEST_TMPDIR/act.args" ] || fail "act was run anyway"
}

@test "a failed provisioning stops the smoke, and says how to start it over" {
  cd "$work"
  git push -q origin feature
  WORKFLOWS_SMOKE_ACCEPT_ANDROID_LICENSES=1 FAKE_SDK_PROVISION_EXIT=1 run bash "$SCRIPT" --android
  [ "$status" -ne 0 ] || fail "output: $output"
  contains "$output" "could not provision the Android SDK in smoke-local-android-sdk" || fail "output: $output"
  contains "$output" "docker volume rm smoke-local-android-sdk" || fail "output: $output"
  [ ! -f "$BATS_TEST_TMPDIR/act.args" ] || fail "act was run anyway"
}

@test "an unknown flag is refused" {
  cd "$work"
  run bash "$SCRIPT" --ios
  [ "$status" -ne 0 ] || fail "an unknown flag was accepted: $output"
  contains "$output" "unknown argument" || fail "output: $output"
}

@test "every ref an artifact step names gets the substitute, once" {
  cd "$work"
  printf 'jobs:\n  a:\n    steps:\n      - uses: actions/upload-artifact@0123456789abcdef0123456789abcdef01234567 # v7.9.9\n      - uses: actions/upload-artifact@v7\n' \
    > .github/workflows/extra.yml
  git push -q origin feature
  run bash "$SCRIPT"
  [ "$status" -eq 0 ] || fail "output: $output"
  args="$(cat "$BATS_TEST_TMPDIR/act.args")"
  contains "$args" "actions/upload-artifact@0123456789abcdef0123456789abcdef01234567=$WORKFLOWS_ACT_CACHE/upload-artifact-v4.6.2" \
    || fail "a new pinned ref is not substituted: $args"
  [ "$(grep -cx "actions/upload-artifact@v7=$WORKFLOWS_ACT_CACHE/upload-artifact-v4.6.2" "$BATS_TEST_TMPDIR/act.args")" -eq 1 ] \
    || fail "a ref named in two workflows is substituted more than once: $args"
}

@test "refuses to run act when no workflow names an artifact action" {
  cd "$work"
  find .github/workflows -name '*.yml' ! -name self-smoke-local.yml -delete
  git push -q origin feature
  run bash "$SCRIPT"
  [ "$status" -ne 0 ] || fail "the smoke ran with nothing to substitute: $output"
  contains "$output" "nothing for act to substitute" || fail "output: $output"
  [ ! -f "$BATS_TEST_TMPDIR/act.args" ] || fail "act was run anyway"
}
