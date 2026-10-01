// The store notes as CD drafts them, through this checkout's real code end to
// end: build-env.sh publishing a caller's environment-variables,
// pr-store-notes.sh drafting the section into a release-please PR, then, after
// release-please's split of the merged body, gen-store-notes.sh reading the
// section back the way build-prepare does for the release lanes. Only two
// things are stood in for: `gh` (a shim serving a real release-please PR body
// and recording the edit) and the model (lib/openai-stub.mjs).
//
// The bats files test each script on its own, and the store-notes app suite
// tests an app's prompt and locales against the generator; this proves the
// pieces still fit. It used to live in the template, which ran it only with a
// shared-workflows checkout at hand.
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { after, test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { startOpenAiStub } from '../packages/app-tooling/lib/openai-stub.mjs';

const REPO = fileURLToPath(new URL('..', import.meta.url));
const SCRIPTS = path.join(REPO, 'scripts', 'release');
const PR_BODY = path.join(REPO, 'packages/app-tooling/fixtures/store-notes/release-pr-body.md');
const BEGIN = '<!-- workflows:append:Store notes -->';
const END = '<!-- /workflows:append:Store notes -->';
const PROSE = 'You can now keep the security gate on your own machine, and a blank laptop is ready for Android and iOS in one step.';
const APP_PROMPT = 'Write for people who run the app, not for the people who build it.';

const dirs = [];
after(() => {
  for (const dir of dirs) rmSync(dir, { recursive: true, force: true });
});
const scratch = (prefix) => {
  const dir = mkdtempSync(path.join(tmpdir(), prefix));
  dirs.push(dir);
  return dir;
};

/** `$GITHUB_ENV` as a map: both the `KEY=value` and the `KEY<<DELIMITER` forms. */
function readGithubEnv(file) {
  const env = {};
  if (!existsSync(file)) return env;
  const lines = readFileSync(file, 'utf8').split('\n');
  for (let i = 0; i < lines.length; i++) {
    const heredoc = /^([A-Za-z_]\w*)<<(.+)$/.exec(lines[i]);
    if (heredoc) {
      const end = lines.indexOf(heredoc[2], i + 1);
      env[heredoc[1]] = lines.slice(i + 1, end).join('\n');
      i = end;
      continue;
    }
    const plain = /^([A-Za-z_]\w*)=(.*)$/.exec(lines[i]);
    if (plain) env[plain[1]] = plain[2];
  }
  return env;
}

/** Runs a shell script without blocking this process, so the stub model can answer. */
function run(script, args, env, cwd) {
  return new Promise((resolve) => {
    const child = spawn('bash', [script, ...args], { cwd, env });
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', (chunk) => {
      stdout += chunk;
    });
    child.stderr.on('data', (chunk) => {
      stderr += chunk;
    });
    child.on('close', (code) => resolve({ code, stdout, stderr }));
  });
}

/** An app with a prompt addendum and one store listing locale. */
function consumerApp() {
  const app = scratch('store-notes-app-');
  mkdirSync(path.join(app, 'fastlane/metadata/ios/en-US'), { recursive: true });
  writeFileSync(path.join(app, 'store-notes.prompt.md'), `${APP_PROMPT}\n`);
  return app;
}

/** A `gh` that serves the PR body for `pr view` and records `pr edit`. */
function ghShim(dir) {
  const bin = path.join(dir, 'bin');
  mkdirSync(bin);
  const shim = path.join(bin, 'gh');
  writeFileSync(
    shim,
    [
      '#!/usr/bin/env bash',
      'set -euo pipefail',
      'printf "%s\\n" "$*" >> "$GH_SHIM_LOG"',
      'case "$1 $2" in',
      '  "pr view") cat "$GH_SHIM_BODY" ;;',
      '  "pr edit") while [ $# -gt 0 ]; do [ "$1" = --body-file ] && cp "$2" "$GH_SHIM_EDITED"; shift; done ;;',
      '  *) echo "gh shim: unexpected $*" >&2; exit 1 ;;',
      'esac',
      '',
    ].join('\n'),
  );
  chmodSync(shim, 0o755);
  return bin;
}

/**
 * The store-notes job, step by step: build-env.sh publishes `environment`
 * (the caller's environment-variables, as JSON), then pr-store-notes.sh drafts
 * into the fixture release PR with that environment and `secrets`.
 */
async function draftIntoReleasePr({ environment = {}, secrets = {} } = {}) {
  const dir = scratch('store-notes-chain-');
  const app = consumerApp();
  const bin = ghShim(dir);
  const files = { githubEnv: path.join(dir, 'github-env'), log: path.join(dir, 'gh.log'), edited: path.join(dir, 'edited.md') };
  // Nothing from the developer's shell: a key or provider exported there would
  // change what this test exercises.
  const base = {
    PATH: `${bin}:${path.dirname(process.execPath)}:/usr/bin:/bin`,
    HOME: dir,
    GITHUB_WORKSPACE: app,
    WORKING_DIRECTORY: '.',
    RUNNER_TEMP: dir,
    WORKFLOWS_OUT: path.join(dir, 'out'),
    GITHUB_ENV: files.githubEnv,
  };
  const published = await run(path.join(SCRIPTS, 'build-env.sh'), [], { ...base, WORKFLOWS_BUILD_ENV: JSON.stringify(environment) }, app);
  assert.equal(published.code, 0, `build-env.sh refused the environment-variables:\n${published.stderr}`);

  const drafted = await run(
    path.join(SCRIPTS, 'pr-store-notes.sh'),
    ['67'],
    {
      ...base,
      ...readGithubEnv(files.githubEnv),
      GH_REPO: 'acme/app',
      GH_TOKEN: 'unused-by-the-shim',
      GH_SHIM_BODY: PR_BODY,
      GH_SHIM_LOG: files.log,
      GH_SHIM_EDITED: files.edited,
      ...secrets,
    },
    app,
  );
  return {
    ...drafted,
    dir,
    app,
    edited: existsSync(files.edited) ? readFileSync(files.edited, 'utf8') : null,
    ghCalls: existsSync(files.log) ? readFileSync(files.log, 'utf8').trim().split('\n') : [],
    release: path.join(dir, 'out', 'build-info'),
  };
}

/** The Store notes section of a PR body, between its markers. */
const sectionOf = (body) => body.slice(body.indexOf(BEGIN), body.indexOf(END));

/** Whether a run left the release PR as it was: not edited at all, or edited to the same body. */
const leftAsItWas = (result) => result.edited === null || result.edited === readFileSync(PR_BODY, 'utf8');

/** A model that answers every request with `reply`, for the length of `use`. */
async function withModel(reply, use) {
  const model = await startOpenAiStub(() => reply);
  try {
    return await use(model);
  } finally {
    await model.close();
  }
}

const openai = (model, environment = {}) => ({
  environment: { STORE_NOTES_LLM_PROVIDER: 'openai', OPENAI_BASE_URL: model.baseUrl, ...environment },
  secrets: { OPENAI_API_KEY: 'sk-test' },
});

test('with no provider the release PR keeps the generated notes it already has', async () => {
  const result = await draftIntoReleasePr();
  assert.equal(result.code, 0, result.stderr);
  // The fixture already carries the generated section, so a correct run
  // rebuilds exactly the same body.
  assert.equal(result.ghCalls[0], 'pr view 67 --repo acme/app --json body --jq .body');
  assert.ok(leftAsItWas(result), `the release PR body changed:\n${result.edited}`);
  assert.match(readFileSync(path.join(result.release, 'store-notes.txt'), 'utf8'), /^New\n• Add the local half of the security gate\./);
});

test("a provider set through environment-variables rewrites the section with the app's prompt, replacing the old one", async () => {
  await withModel({ status: 200, content: JSON.stringify({ 'en-US': PROSE }) }, async (model) => {
    const result = await draftIntoReleasePr(
      openai(model, { STORE_NOTES_LLM_MODEL: 'any-model', STORE_NOTES_LLM_EFFORT: 'none', STORE_NOTES_LLM_EXTRA_PARAMS: '{"response_format": null}' }),
    );
    assert.equal(result.code, 0, result.stderr);
    assert.doesNotMatch(result.stderr, /store notes: /);
    assert.equal(model.requests.length, 1);
    const [{ url, body }] = model.requests;
    assert.equal(url, '/v1/chat/completions');
    assert.equal(body.model, 'any-model');
    assert.equal('reasoning_effort' in body, false);
    assert.equal('response_format' in body, false);
    assert.match(body.messages[0].content, new RegExp(APP_PROMPT));
    assert.match(body.messages[1].content, /Add the release-time security scanners/);

    assert.ok(result.edited, 'the release PR was not edited');
    assert.equal(result.edited.split(BEGIN).length - 1, 1, 'the section was stacked, not replaced');
    assert.match(sectionOf(result.edited), new RegExp(PROSE));
    assert.doesNotMatch(sectionOf(result.edited), /• Add the local half/);
    assert.match(result.edited, /\n---\nThis PR was generated with \[Release Please\]/);
  });
});

test('a model that fences its answer still rewrites the section', async () => {
  await withModel({ status: 200, content: `\`\`\`json\n${JSON.stringify({ 'en-US': PROSE })}\n\`\`\`` }, async (model) => {
    const result = await draftIntoReleasePr(openai(model));
    assert.equal(result.code, 0, result.stderr);
    assert.match(sectionOf(result.edited), new RegExp(PROSE));
  });
});

test('a model that fails leaves the generated notes and a warning, never a failed job', async () => {
  await withModel({ status: 500, content: '' }, async (model) => {
    const result = await draftIntoReleasePr(openai(model));
    assert.equal(result.code, 0, result.stderr);
    assert.match(result.stderr, /store notes: openai rewrite failed \(openai: HTTP 500\)/);
    assert.ok(leftAsItWas(result), `the release PR body changed:\n${result.edited}`);
  });
});

test('the section written into the release PR is what the release lanes read back', async () => {
  const drafted = await withModel({ status: 200, content: JSON.stringify({ 'en-US': PROSE }) }, (model) => draftIntoReleasePr(openai(model)));
  assert.ok(drafted.edited, 'the release PR was not edited');

  // release-please makes the GitHub release body from the text between the
  // first and the last `---` line of the merged PR body. Simulated here: this
  // is release-please's documented behaviour, not code this run can call.
  const lines = drafted.edited.split('\n');
  const releaseBody = path.join(drafted.dir, 'release-body.md');
  writeFileSync(releaseBody, lines.slice(lines.indexOf('---') + 1, lines.lastIndexOf('---')).join('\n'));

  // build-prepare with `release-tag`: gen-store-notes.sh on the release body,
  // with no model settings at all - the CD lanes carry none.
  const out = path.join(drafted.dir, 'lanes');
  const read = await run(
    path.join(SCRIPTS, 'gen-store-notes.sh'),
    [],
    {
      PATH: `${path.dirname(process.execPath)}:/usr/bin:/bin`,
      HOME: drafted.dir,
      GITHUB_WORKSPACE: drafted.app,
      WORKING_DIRECTORY: '.',
      RUNNER_TEMP: drafted.dir,
      WORKFLOWS_OUT: out,
      RELEASE_BODY_FILE: releaseBody,
    },
    drafted.app,
  );
  assert.equal(read.code, 0, read.stderr);
  assert.equal(readFileSync(path.join(out, 'build-info', 'store-notes.txt'), 'utf8'), `${PROSE}\n`);
});
