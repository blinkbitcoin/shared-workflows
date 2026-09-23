# Security policy

## Reporting a vulnerability

Report privately. Do **not** open a public issue, and do not describe the
problem in a pull request.

- Preferred: GitHub → **Security** → **Report a vulnerability** (private
  security advisory) on this repository.
- Email: `security@blink.sv` *(placeholder — replace with the real address for
  your fork before publishing this repository)*.

Include the workflow, action or script involved, the ref you pin (`@v0`, a tag
or a sha), and the smallest caller that reproduces it. Expect an
acknowledgement within a few working days. Please give us a reasonable window
to ship a fix and move the `v0` tag before disclosing publicly.

This repository is CI machinery, so the interesting class of bug is one that
lets a pull request influence what a consumer's job executes or what it can
read. Say so explicitly if that is what you have found.

## Supported versions

Only `main` and the moving major tag (`v0`) are supported. An older tag gets no
backported fixes — a consumer is expected to move its pin forward.

## Threat model

- **Callers are trusted; PR content is not.** Anything a contributor controls —
  a PR title, a branch name, a commit message, a changed path — is treated as
  data: it is read from the environment and piped to the tool that parses it,
  never interpolated into a shell string or a `run:` block. See the header of
  `scripts/checks/commitlint.sh` for the worked example.
- **`pull_request_target` is not used**, and no workflow here checks out a
  fork's head with a privileged token.
- **Permissions start at `contents: read`.** A job that needs more declares the
  extra scope and re-declares `contents: read`, because a job-level
  `permissions:` block replaces the top-level one instead of extending it.
- **Third-party actions are pinned to a major tag** and bumped as a group by
  Dependabot. That is a deliberate trade: a major tag still moves under us, so
  the mitigation is that the set is small, first-party or well-known, and
  reviewed on every bump. A consumer that needs immutability pins this
  repository by sha rather than `@v0`, which fixes the action set too.
- **The `.workflows/` self-checkout must resolve to this repository.** Every job
  checks itself out via `job.workflow_repository` / `job.workflow_sha`; a
  regression there would run someone else's scripts under the consumer's token,
  which is why `test/workflow-shape.bats` asserts the pattern.

## Secrets policy

- **Nothing secret goes in the repository.** No token, keystore, service
  account or store credential is committed, and the bats fixtures use obvious
  dummies.
- **Secrets are declared, never inherited implicitly.** A reusable workflow
  lists what it needs under `secrets:`; consumers pass exactly that. Most of
  the family runs on `github.token` alone.
- **Secrets stay out of logs and outputs.** Decoded signing material is written
  to a runner-temp path and removed; a workflow output must never carry a
  secret, since outputs are readable by the calling workflow's whole graph.
- If a secret is exposed, treat it as compromised: rotate first, then clean up
  history.

Dependency exposure on the consumer side is watched by `check-code.yml`'s audit
step; this repository's own dependencies are the pinned tools in `.mise.toml`
and the actions pinned in `.github/workflows/`, both watched by Dependabot
(`.github/dependabot.yml`).
