.DEFAULT_GOAL := help
SHELL := /bin/bash

# Every pinned tool (.mise.toml) is run through $(MISE), so a recipe gets the
# pinned version whoever calls make: a shell with mise activated, CI after
# mise-action, or a caller that activated nothing - a git hook run from an IDE,
# a GUI client or an agent. Otherwise the wrapping is every caller's job, and
# the one that forgets dies on `bats: No such file`. A prefix rather than an
# exported PATH: macOS ships make 3.81, which execs a simple recipe line itself
# and searches the PATH it was started with, not the one the makefile exports.
# No mise, no prefix: the tools are then the caller's to provide, as before.
MISE := $(shell command -v mise >/dev/null 2>&1 && echo 'mise exec --')

# Every recipe line of every gate `make check` runs is timed: $(TIMED) runs it
# through scripts/self/time-step.mjs, which appends how long it took to
# $(TIMING_DIR)/targets.jsonl, and the test targets write a JUnit report beside
# it with each test's time. `check` and `test` end by printing where the time
# went (scripts/self/timing-report.mjs); `make report-timing` prints it again
# for the newest run, including one a failing gate stopped before its report.
# The command after $(TIMED) needs no $(MISE) of its own: time-step.mjs runs
# under mise, and starts the command with mise's PATH.
#
# A run is named once, when make starts (`:=`, not `?=`, which would take a new
# timestamp at every expansion); self-ci names its own, one per job.
ifndef TIMING_RUN
TIMING_RUN := $(shell date +%Y%m%dT%H%M%S)
endif
TIMING_DIR ?= .timing/$(TIMING_RUN)
export TIMING_RUN TIMING_DIR
TIMED = $(MISE) node scripts/self/time-step.mjs $@ --

# shellcheck, actionlint and zizmor: the three linters of the CI code, one
# gate, as `check-ci` is one gate in a consumer.
#
# `find`, not `scripts/*/*.sh`: that glob is fixed at depth 2, so a script one
# directory deeper is skipped silently. Same form as scripts/ci/check-ci.sh.
#
# The --offline flag of zizmor: the online audits call the GitHub API, and a gate must give
# the same answer without a network. Policy (tag pins allowed) in
# .github/zizmor.yml, passed with --config: zizmor looks for it at the nearest
# directory holding a `.git` *directory*, and a worktree's `.git` is a file, so
# from a worktree nested in another checkout (`.claude/worktrees/<name>/`) it
# would read that checkout's policy instead of this one's.
check-ci: ## Lint the scripts (shellcheck), the workflows and actions (actionlint) and audit their security (zizmor)
	$(TIMED) find scripts plugins -name '*.sh' -exec shellcheck -x {} +
	$(TIMED) actionlint -color
	$(TIMED) zizmor --offline --min-severity medium --config .github/zizmor.yml .github
# One bats job per core: the suite is about 1,200 cases that each start a
# handful of processes, so on one core it took eight minutes and on eighteen it
# takes two. `bats --jobs` needs GNU parallel; without it the suite still runs,
# one case at a time. Every test therefore has to stand alone - its own temp
# directory, no fixed wait for a background process (poll for it), no path
# another test writes (see CONTRIBUTING.md).
BATS_JOBS := $(shell command -v parallel >/dev/null 2>&1 && (getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4) || echo 1)
test-unit: ## bats over the scripts, the workflows' shape and the docs' facts, one job per core
	$(TIMED) bats --jobs $(BATS_JOBS) --timing --report-formatter junit --output $(TIMING_DIR) test/
# packages/app-tooling/versions.json is the one file a version is edited in;
# scripts/lib/versions.sh (and its package copy) and the [tools] block of
# .mise.toml are generated from it. First that nothing generated has drifted
# (fix: node scripts/self/render-versions.mjs --write), then that the workflow
# and action input defaults, which stay hand-written, agree with it.
check-version-pins: ## Fail when versions.sh or .mise.toml is not what versions.json generates, or a workflow default disagrees
	$(TIMED) node scripts/self/render-versions.mjs --check
	$(TIMED) bash scripts/self/check-version-pins.sh
check-tool-versions: ## Fail when an installed tool is not the version the baseline pins
	$(TIMED) node packages/app-tooling/bin/check-tool-versions.mjs
# Every package under packages/, at 100% lines, branches and functions. The
# exclusions are the tests themselves (node's default, which naming any
# exclusion replaces) and each package's fixtures/: the configuration files a
# preset test evaluates as the consumer has them and the stand-ins for the
# consumer's tools, not code of the package. Never lower a threshold or widen
# an exclusion to make a change fit.
test-package: ## node:test for every package under packages/, with the 100% coverage gate
	$(TIMED) node --test --experimental-test-coverage \
		--test-reporter=spec --test-reporter-destination=stdout \
		--test-reporter=junit --test-reporter-destination=$(TIMING_DIR)/test-package.xml \
		--test-coverage-lines=100 --test-coverage-branches=100 --test-coverage-functions=100 \
		--test-coverage-exclude='**/*.test.mjs' --test-coverage-exclude='**/*.suite.mjs' --test-coverage-exclude='packages/*/fixtures/**' \
		"packages/*/**/*.test.mjs"
# The Node scripts under scripts/ each have their own node:test file under
# test/, and the gate is 100% of lines, branches and functions over them.
test-scripts: ## node:test for the Node scripts under scripts/, with the 100% coverage gate
	$(TIMED) node --test --experimental-test-coverage \
		--test-reporter=spec --test-reporter-destination=stdout \
		--test-reporter=junit --test-reporter-destination=$(TIMING_DIR)/test-scripts.xml \
		--test-coverage-lines=100 --test-coverage-branches=100 --test-coverage-functions=100 \
		--test-coverage-include='scripts/**/*.mjs' \
		"test/*.test.mjs"
# The Ruby lanes under packages/app-tooling/fastlane: their unit tests, the
# recorded lane arguments replayed against the real fastlane actions, and the
# package Fastfile loaded by real fastlane. See scripts/self/test-fastlane.sh.
test-fastlane: ## Unit tests of the fastlane lanes the package ships (Ruby; installs the gems into .gems/)
	$(TIMED) bash scripts/self/test-fastlane.sh
check-spell: ## typos over the whole repo
	$(TIMED) typos
check-secrets: ## Scan the whole git history for committed secrets (gitleaks)
	$(TIMED) gitleaks git --redact --no-banner .
# The report is advice, never a gate: the leading `-` lets make carry on past a
# report that fails, so timing adds no way for `make check` (the pre-push hook)
# to fail.
test: test-unit test-package test-scripts test-fastlane ## Every test suite: bats, the packages, the Node scripts and the Ruby lanes
	-$(MISE) node scripts/self/timing-report.mjs $(TIMING_DIR)
check: check-ci test-unit test-package test-scripts test-fastlane check-version-pins check-tool-versions check-spell check-secrets ## Everything self-ci runs
	-$(MISE) node scripts/self/timing-report.mjs $(TIMING_DIR)
report-timing: ## Show where the last check or test run spent its time
	$(MISE) node scripts/self/timing-report.mjs
# Not part of `check`: needs Docker and a pushed branch, and takes a few minutes
# (the Android leg longer). See CONTRIBUTING.md, "Running the release pipeline
# locally".
test-smoke-local: ## Run Prepare against the template with act (the Linux jobs, in Docker; needs a pushed branch)
	$(MISE) bash scripts/self/smoke-local.sh
test-smoke-local-android: ## test-smoke-local, then the unsigned Android build
	$(MISE) bash scripts/self/smoke-local.sh --android
# Where a GitHub Actions run spent its time, read with your own gh login:
# make report-run-timing RUN=<run URL> [ARGS='--logs --compare <run URL>'].
# The check is make's own, so an empty RUN names the variable, not just the usage.
report-run-timing: ## Show where a GitHub Actions run spent its time (RUN=<run URL>, ARGS=<more trace-run options>)
	$(if $(RUN),,$(error RUN is empty: make report-run-timing RUN=<run URL> [ARGS='--logs --compare <run URL>']))
	$(MISE) node packages/app-tooling/bin/trace-run.mjs $(RUN) $(ARGS)
# Clone-wide, not worktree-scoped: a git worktree shares .git/hooks with the
# main checkout, so this installs the hooks for every worktree of this clone.
setup-hooks: ## Install the git hooks (lefthook) - affects the whole clone, not just this worktree
	$(MISE) lefthook install
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-16s\033[0m %s\n", $$1, $$2}'
.PHONY: check-ci check-secrets report-timing test test-unit test-package test-scripts test-fastlane check-version-pins check-tool-versions check-spell check test-smoke-local test-smoke-local-android report-run-timing setup-hooks help
