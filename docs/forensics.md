# Forensics

What `check-e2e.yml` and `build-web.yml` upload when something goes wrong, and how to read
it. Every forensics step runs with `if: always()`, so it uploads on both pass
and fail (a green run's artifact is usually small and worth skimming anyway).

## What it costs

Roughly **50–100 MB per platform per run** — mostly the screen recording and
the per-command Maestro screenshots — kept for **7 days** (the `forensics`
action's `retention-days` input). `test/workflow-shape.bats` pins the
`if: always()` condition, because the tempting way to cut that bill is to
switch it to `failure()`, and that throws away exactly the artifacts that turn
a later "it passed that time" into a diagnosis. **The lever is
`retention-days`, not `if:`** — pass a smaller number to the `forensics` action
(or a larger one for a branch you are bisecting) and leave the condition alone.

## Where it comes from

`scripts/e2e/collect-forensics.sh <ios|android>` always exits `0` (a forensics
failure must never fail the job) and writes into `$WORKFLOWS_OUT/forensics`:

- `metro.log` — the bundler's full stdout/stderr for the run.
- `*.mp4` — the screen recording (`ios-simulator.sh record start|stop` /
  `android-emulator.sh record start|stop`), started right before the app
  launches and stopped in the `always()` teardown step.
- iOS only: crash reports (`*.ips`, `*.crash`) copied from
  `~/Library/Logs/DiagnosticReports`, filtered to files newer than
  `$WORKFLOWS_RUN_START` (a timestamp file stamped once per job by whichever script
  sources `scripts/lib/e2e-env.sh` first) so a stale crash from a previous job
  on the same runner never shows up. If that stamp is missing for some reason
  the fallback is "modified in the last 60 minutes".
- iOS only: `ios-unified.log` — the simulator's unified log for the same
  window as the video (`ios-simulator.sh record start` spawns
  `simctl log stream`, `record stop` ends it), filtered by
  `scripts/lib/e2e-env.sh`'s `workflows_ios_unified_log_predicate` to
  SpringBoard's alert lifecycle (`AlertItems`, `AlertItemStack`,
  `SceneDeactivation`), FrontBoard's scene-action delivery (`SceneClient`) and
  any line naming the app id or its URL scheme. It exists for the deep link
  that "did nothing": `Presenting <SBUserNotificationAlert` is the
  "Open in <app>?" prompt, `Will deactivate alertItem` is the tap on it, and
  the `url = <scheme>://…` block is the `UIOpenURLAction` reaching the app.
  On a runner the gap between that block and the next navigation is where
  the time went; locally the same binary does it in 40 ms.
- `maestro/` — the whole Maestro debug directory (`junit.xml` plus the
  per-command screenshots and device logs), copied in from its sibling
  `$WORKFLOWS_OUT/maestro`. Only `forensics/` is uploaded, so this copy is what puts
  the Maestro output in the artifact at all.
- Android only: `logcat.txt` (full buffer) and `logcat-crash.txt` (the crash
  buffer). The step also prints two `::group::` blocks straight into the job
  log so you don't have to download anything for the common case: the last 200
  lines of the crash buffer, and the last 200 lines of `logcat.txt` matching
  `ReactNativeJS|AndroidRuntime|FATAL|Fatal signal|lowmemorykiller|has died|app died`.

The `forensics` composite action then uploads `$WORKFLOWS_OUT/forensics` (or
`playwright-report/` for the web workflow) as an artifact and calls
`scripts/ci/artifact-summary.sh`, which writes a table with the artifact's
download URL and, when a `junit` path was given, the pass/fail/total counts
parsed out of it, straight into the job's step summary — so the first thing to
check is the **Summary** tab of the run, not the artifact.

If the run died before Maestro wrote `junit.xml` (the emulator never booted, the
app-launch timed out, the suite hit its bound) the summary step logs a
`::warning::` and posts the summary without counts — it never fails, because it
runs from the same `if: always()` step that carries the diagnosis.

## Reading the Maestro debug output

`ios-maestro.sh` / `android-maestro.sh` pass Maestro:

```
--debug-output "$WORKFLOWS_OUT/maestro" --flatten-debug-output --format junit --output "$WORKFLOWS_OUT/maestro/junit.xml"
```

Inside the `forensics-ios` / `forensics-android` artifact, under `maestro/`,
you'll find:

- `junit.xml` — machine-readable pass/fail per flow; this is what
  `artifact-summary.sh` totals for the step summary.
- `--flatten-debug-output` puts every flow's debug files (device logs,
  per-command screenshots, the recorded command hierarchy) directly in
  `maestro/` instead of nested per-run subdirectories — the naming is
  `<flowName>-<commandIndex>-<label>.png`/`.txt`; sort by flow name to follow
  one flow's timeline.
- Maestro writes a screenshot per command it executes, so scanning the
  numbered PNGs in flow order shows the UI state right up to the failing
  command without needing to scrub the video.

## A suite with no flow output at all

If the job log shows `Requested 1 shards…` and then nothing until
`Maestro suite exceeded …s`, no flow ran: open `maestro/xctest_runner_*.log`
in the artifact and look for `Simulator device failed to launch
dev.mobile.maestro-driver-iosUITests.xctrunner` / `** TEST EXECUTE FAILED **`.
That is Maestro's own XCUITest runner failing to start on the simulator (seen
on a runner where `Setup` alone took 5 minutes), not the app and not a flow.
Maestro polls the dead driver until `MAESTRO_DRIVER_STARTUP_TIMEOUT`, so that
value is kept strictly below the suite bound: the failure then surfaces as
`iOS driver not ready in time`, a real exit status, and the suite is rerun
once - which reinstalls and relaunches the runner. `ios-unified.log` will be
quiet for the whole window, which is itself the confirmation.

## The suite retry and what it means for forensics

Both platform scripts retry the suite exactly once on a **real** failure
(`status != 0 && status != 124`) — a timeout (`124`, from `maestro-bound.sh`)
is never retried, because a hung driver would just burn the timeout twice. The
recording and forensics you get are from **whichever attempt is the exit
status of the step** — the retry replaces the first attempt's Maestro debug
output on disk before `collect-forensics.sh` runs, so if the suite failed then
passed on retry, the uploaded video/log are the retry's, not the failure's. If
you need to see the first attempt's flake, re-run with
`maestro-include-tags`/`exclude-tags` narrowed to the flaky flow, or watch the
job log directly — the `::group::` blocks for both attempts stay in the raw
log even though the artifact only carries the final attempt's files.

## Video

- iOS: `xcrun simctl io <udid> recordVideo`, started right after install, wait
  and Metro warm-up, stopped in the always-run teardown.
- Android: a background loop in `android-emulator.sh record start` running
  `adb shell screenrecord --time-limit 180` over and over (the emulator caps a
  single recording at ~3 minutes), pulling each finished chunk to its own
  `$WORKFLOWS_OUT/android-N.mp4`; `record stop` kills the loop and pulls the
  in-progress chunk as `android-last.mp4`. Nothing concatenates — a long suite
  leaves several numbered files, in order, and `collect-forensics.sh` copies
  them all out.
- The video covers install → launch → suite, so a UI assertion failure near
  the end of a long suite is often faster to diagnose by scrubbing to the last
  30 seconds of the video than by replaying every Maestro screenshot.

## build-web.yml (Playwright)

`build-web.yml`'s `playwright` job forensics step uploads `playwright-report/` (Playwright's
own HTML report, traces and screenshots) as `playwright-report`; open
`index.html` locally (`npx playwright show-report <dir>`) for the interactive
trace viewer — it's more useful than the individual PNGs for a web failure.
