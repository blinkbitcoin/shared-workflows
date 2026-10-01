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
	find scripts -name '*.sh' -exec $(MISE) shellcheck -x {} +
	$(MISE) actionlint -color
	$(MISE) zizmor --offline --min-severity medium --config .github/zizmor.yml .github
# One bats job per core: the suite is about 1,200 cases that each start a
# handful of processes, so on one core it took eight minutes and on eighteen it
# takes two. `bats --jobs` needs GNU parallel; without it the suite still runs,
# one case at a time. Every test therefore has to stand alone - its own temp
# directory, no fixed wait for a background process (poll for it), no path
# another test writes (see CONTRIBUTING.md).
BATS_JOBS := $(shell command -v parallel >/dev/null 2>&1 && (getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4) || echo 1)
test-unit: ## bats over the scripts, the workflows' shape and the docs' facts, one job per core
	$(MISE) bats --jobs $(BATS_JOBS) test/
check-version-pins: ## Fail when workflow defaults disagree with scripts/lib/versions.sh
	$(MISE) bash scripts/self/check-version-pins.sh
check-tool-versions: ## Fail when an installed tool is not the version the baseline pins
	$(MISE) node packages/app-tooling/bin/check-tool-versions.mjs
# Every package under packages/, at 100% lines, branches and functions. The
# exclusions are the tests themselves (node's default, which naming any
# exclusion replaces) and each package's fixtures/: the configuration files a
# preset test evaluates as the consumer has them and the stand-ins for the
# consumer's tools, not code of the package. Never lower a threshold or widen
# an exclusion to make a change fit.
test-package: ## node:test for every package under packages/, with the 100% coverage gate
	$(MISE) node --test --experimental-test-coverage \
		--test-coverage-lines=100 --test-coverage-branches=100 --test-coverage-functions=100 \
		--test-coverage-exclude='**/*.test.mjs' --test-coverage-exclude='**/*.suite.mjs' --test-coverage-exclude='packages/*/fixtures/**' \
		"packages/*/**/*.test.mjs"
# The Node scripts under scripts/ each have their own node:test file under
# test/, and the gate is 100% of lines, branches and functions over them.
test-scripts: ## node:test for the Node scripts under scripts/, with the 100% coverage gate
	$(MISE) node --test --experimental-test-coverage \
		--test-coverage-lines=100 --test-coverage-branches=100 --test-coverage-functions=100 \
		--test-coverage-include='scripts/**/*.mjs' \
		"test/*.test.mjs"
check-spell: ## typos over the whole repo
	$(MISE) typos
check-secrets: ## Scan the whole git history for committed secrets (gitleaks)
	$(MISE) gitleaks git --redact --no-banner .
test: test-unit test-package test-scripts ## Every test suite: bats, the packages and the Node scripts
check: check-ci test-unit test-package test-scripts check-version-pins check-tool-versions check-spell check-secrets ## Everything self-ci runs
# Not part of `check`: needs Docker, a pushed branch and a few minutes. See
# CONTRIBUTING.md, "Running the release pipeline locally".
test-smoke-local: ## Run Prepare against the template with act (the Linux jobs, in Docker; needs a pushed branch)
	$(MISE) bash scripts/self/smoke-local.sh
test-smoke-local-android: ## test-smoke-local, then the unsigned Android build
	$(MISE) bash scripts/self/smoke-local.sh --android
# Clone-wide, not worktree-scoped: a git worktree shares .git/hooks with the
# main checkout, so this installs the hooks for every worktree of this clone.
setup-hooks: ## Install the git hooks (lefthook) - affects the whole clone, not just this worktree
	$(MISE) lefthook install
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-16s\033[0m %s\n", $$1, $$2}'
.PHONY: check-ci check-secrets test test-unit test-package test-scripts check-version-pins check-tool-versions check-spell check test-smoke-local test-smoke-local-android setup-hooks help
