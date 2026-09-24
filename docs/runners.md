# Runners

## macOS billing

**On a private repo**, GitHub-hosted macOS runners bill at **10x** the Linux
rate. `check-e2e.yml`'s `ios` input therefore defaults to `false`, and `android`
defaults to `true` — the Android suite runs on `ubuntu-latest` at 1x. Turn iOS
on deliberately, per caller, once you have budgeted for it.

**On a public repo, standard GitHub-hosted runners are free, macOS included,**
so there is no billing reason to leave iOS off and it should be on. The default
stays `false` because it is the safe one for the private app repos this family
mostly serves — a default that silently spends money is worse than one that
silently skips a suite — but a public repo should set `E2E_IOS=true` and get
the coverage for nothing.

What remains true either way is wall-clock: iOS takes roughly three times as
long as Android, and public repos have their own concurrency caps on macOS
jobs. That is a scheduling argument, not a cost one, and it is why the
consumer guide's `ci.yml` runs iOS on pushes to `main` and keeps it off PRs
unless one carries the `e2e:ios` label.

`macos-runner` (default `macos-26`) is a workflow input on every family member
that takes inputs at all — the exception is `pr-closed.yml`, which takes none —
so a caller can pin an older or newer image without editing this repo. Consumers that want a repo-wide override without touching every caller
workflow can instead read it from a repo variable:

```yaml
macos-runner: ${{ vars.WORKFLOWS_MACOS_RUNNER || 'macos-26' }}
```

`WORKFLOWS_MACOS_RUNNER` is not read by any workflow in this repo directly — it's a
convention for the consumer's own caller workflows (see
`docs/consumer-guide.md`), which is why it's a repo *variable* the consumer
sets, not an input this repo defines a default for.

## Self-hosted runners

Nothing in this family requires self-hosting, but every `runs-on:` in the
reusable workflows is a plain input (`linux-runner`, `macos-runner`), so a
consumer can point them at self-hosted labels (e.g. `['self-hosted', 'linux',
'x64']` as a JSON array passed through the input, or a single label string) to
cut cost or get GPU-backed Android emulation. Two things change on
self-hosted:

- `free-disk` and `enable-kvm` (`scripts/ci/free-disk.sh`,
  `scripts/ci/enable-kvm.sh`) both **skip themselves with a log line** unless
  `GITHUB_ACTIONS=true` *and* `RUNNER_OS=Linux` — true on any Linux
  self-hosted runner too, so they still run there. Set
  `WORKFLOWS_FORCE_RUNNER_SCRIPTS=1` to force them on a runner that reports
  differently (rare) or when testing locally in an actions-like container.
- `actionlint.yaml`'s `self-hosted-runner.labels` is empty in this repo (it
  never runs its own workflows on self-hosted runners), but a consumer with
  self-hosted labels needs its own `.github/actionlint.yaml` entry or
  `actionlint`/`shellcheck` (via `check-code.yml`) will flag the unknown label.

## KVM (Android emulator, Linux)

`enable-kvm.sh` installs a udev rule so the `/dev/kvm` node is group-writable
before `ReactiveCircus/android-emulator-runner` starts — without it the
emulator falls back to software rendering and both the AVD "bake" step and the
suite itself get much slower and less reliable. GitHub-hosted `ubuntu-latest`
runners already have KVM available at the hardware level; this script only
adjusts permissions, it doesn't nest virtualization. If you point `android` at
a self-hosted runner, KVM must already exist on the host (nested
virtualization inside most cloud VMs does not expose `/dev/kvm`) or the step
fails loudly rather than silently degrading.

## Disk space (Linux)

`free-disk.sh` removes `/usr/share/dotnet`, `/opt/ghc`, `/usr/local/.ghcup`,
all but the newest Android NDK version under
`/usr/local/lib/android/sdk/ndk`, and prunes dangling Docker images — all of
it pre-installed tooling `check-e2e.yml`'s Android jobs never use. It runs first,
before Maestro install, KVM setup or the emulator, in the `android` job (the
disk-heaviest job in the family: system image + AVD + APK + emulator + Maestro
CLI can otherwise exhaust a standard runner's ~14GB free). It prints `df -h /`
before and after so a disk-pressure failure is diagnosable straight from the
job log without downloading anything.
