// One commit of shared-workflows, everywhere a consumer takes something from it.
//
// A consumer calls the reusable workflows pinned to a commit SHA, and takes this
// family's package (app-tooling, and any later one under packages/) as a git
// dependency. Dependabot moves the workflow pins and cannot move a git
// dependency with them, so the two part company on every bump unless something
// checks them together. This module is that check's reading of the consumer:
// the contract's `one-pin` row, `fix-tooling-pin` and `check-lockfile` all use it.
//
// Text, not a YAML parser: the package stays dependency-free, and the version
// comment beside a SHA pin is exactly what a YAML parser would throw away.

export const SHARED = 'blinkbitcoin/shared-workflows';

const USES_LINE =
  /^\s*uses:\s*blinkbitcoin\/shared-workflows\/\.github\/workflows\/([\w.-]+)@(\S+?)(?:\s+#\s*(.*\S))?\s*$/;

/**
 * Every `uses:` line in `text` that calls a shared workflow, in file order:
 * `{ line, workflow, ref, comment }`, `comment` being '' when there is none.
 */
export function pinsIn(text) {
  const pins = [];
  for (const [index, line] of text.split('\n').entries()) {
    const match = USES_LINE.exec(line);
    if (match) {
      const [, workflow, ref, comment = ''] = match;
      pins.push({ line: index + 1, workflow, ref, comment });
    }
  }
  return pins;
}

/** Whether `ref` is a full commit SHA rather than a tag or branch. */
export function isCommit(ref) {
  return /^[0-9a-f]{40}$/.test(ref);
}

/**
 * The one ref the callers (`[{ name, text }]`) call shared-workflows at, as
 * `{ pin, problems }`. Every call must use the same ref. A tag such as the
 * guide's `@v0` is allowed; a commit SHA must carry its `# vX.Y.Z`, the only
 * place a reader (and Dependabot) sees which release it is. `pin` is null when
 * `problems` is not empty.
 */
export function workflowsPin(callers) {
  const pins = callers.flatMap(({ name, text }) => pinsIn(text).map((pin) => ({ ...pin, file: name })));
  if (pins.length === 0) return { pin: null, problems: ['no workflow calls shared-workflows'] };
  const problems = [];
  for (const pin of pins) {
    if (isCommit(pin.ref) && !/^v\d+\.\d+\.\d+$/.test(pin.comment)) {
      problems.push(`${pin.file}:${pin.line} has no "# vX.Y.Z" beside its pin`);
    }
  }
  const refs = [...new Set(pins.map((pin) => pin.ref))];
  if (refs.length > 1) {
    problems.push(`the calls pin ${refs.length} refs (${refs.join(', ')}): CI would test one and CD run another`);
  }
  return { pin: problems.length === 0 ? refs[0] : null, problems };
}

const SPEC = /^github:blinkbitcoin\/shared-workflows#([^&]+)&path:(\/packages\/[\w.-]+)$/;

/**
 * This family's packages among `pkg`'s dependencies: every dependency whose spec
 * points at shared-workflows, as `{ name, field, spec, commit, dir }`. `commit`
 * and `dir` are null when the spec is not the `github:...#<sha>&path:` form.
 */
export function sharedDeps(pkg) {
  const found = [];
  for (const field of ['dependencies', 'devDependencies']) {
    for (const [name, spec] of Object.entries(pkg?.[field] ?? {})) {
      if (typeof spec !== 'string' || !spec.includes(SHARED)) continue;
      const match = SPEC.exec(spec);
      found.push({ name, field, spec, commit: match?.[1] ?? null, dir: match?.[2] ?? null });
    }
  }
  return found;
}

/** The dependency spec that takes the package in `dir` from shared-workflows at `commit`. */
export function specFor(commit, dir) {
  return `github:${SHARED}#${commit}&path:${dir}`;
}

/** The tarball pnpm resolves that spec to, as its lockfile writes it. */
export function tarballFor(commit, dir) {
  return `https://codeload.github.com/${SHARED}/tar.gz/${commit}#path:${dir}`;
}

/**
 * Every way the consumer disagrees with one pin: the workflow calls themselves,
 * then each of this family's packages in package.json and in the lockfile.
 * `lockfile` is the text of pnpm-lock.yaml, or null when there is none.
 */
export function pinProblems({ callers, pkg, lockfile }) {
  const { pin, problems } = workflowsPin(callers);
  if (pin === null) return problems;
  // A tag moves, so no package can be held to it: with `@v0` only the calls
  // themselves have to agree.
  if (!isCommit(pin)) return problems;
  for (const dep of sharedDeps(pkg)) {
    if (dep.dir === null) {
      problems.push(`package.json takes ${dep.name} as ${dep.spec}, not github:${SHARED}#<sha>&path:/packages/<name>`);
      continue;
    }
    if (dep.commit !== pin) {
      problems.push(`package.json takes ${dep.name} at ${dep.commit}, but the workflows pin ${pin}: run \`pnpm exec fix-tooling-pin\``);
      continue;
    }
    if (lockfile !== null && !lockfile.includes(`version: ${tarballFor(pin, dep.dir)}\n`)) {
      problems.push(`pnpm-lock.yaml does not resolve ${dep.name} at ${pin}: run \`pnpm exec fix-tooling-pin\``);
    }
  }
  return problems;
}
