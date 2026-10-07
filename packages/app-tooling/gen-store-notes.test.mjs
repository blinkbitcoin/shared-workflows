import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { after, test } from 'node:test';
import { fileURLToPath } from 'node:url';
import {
  APP_PROMPT_FILE,
  buildNotes,
  cleanSection,
  cleanText,
  commitSubjects,
  composePrompt,
  DEFAULT_PROMPT_FILE,
  discoverLocales,
  extractStoreSection,
  fetchBody,
  limitText,
  loadPrompt,
  main,
  parseArgs,
  parseBody,
  parseCommits,
  renderChangelog,
  renderNotes,
  resolveLocales,
  resolveSource,
  STORE_LIMITS,
  TRUNCATION_SUFFIX,
  toStoreNotes,
} from './bin/gen-store-notes.mjs';
import { maxTokensFor, renderPrompt, TESTFLIGHT_LIMIT } from './lib/store-notes-rewrite.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const script = path.join(here, 'bin', 'gen-store-notes.mjs');
const fixtures = path.join(here, 'fixtures', 'store-notes');
const fixture = (name) => readFileSync(path.join(fixtures, name), 'utf8');
const body = fixture('release-body.md');
const dirs = [];

after(() => {
  for (const dir of dirs) rmSync(dir, { recursive: true, force: true });
});

function tempDir() {
  const dir = mkdtempSync(path.join(tmpdir(), 'store-notes-'));
  dirs.push(dir);
  return dir;
}

/** Runs `fn` with `globalThis.fetch` replaced, and restores it afterwards. */
async function withFetch(impl, fn) {
  const original = globalThis.fetch;
  globalThis.fetch = impl;
  try {
    return await fn();
  } finally {
    globalThis.fetch = original;
  }
}

/** Runs `fn` with the given env vars set (empty string = unset), then restores. */
async function withEnv(vars, fn) {
  const previous = {};
  for (const [key, value] of Object.entries(vars)) {
    previous[key] = process.env[key];
    if (value === '') delete process.env[key];
    else process.env[key] = value;
  }
  try {
    return await fn();
  } finally {
    for (const [key, value] of Object.entries(previous)) {
      if (value === undefined) delete process.env[key];
      else process.env[key] = value;
    }
  }
}

/** A fetch that answers once with `payload`, recording the call it received. */
function stubFetch(payload, calls, ok = true) {
  return async (url, init) => {
    calls.push({ url, init });
    return { ok, status: ok ? 200 : 500, json: async () => payload };
  };
}

// ---------- deterministic renderer ----------

test('a release-please body renders as grouped, store-safe prose', () => {
  const notes = renderNotes(parseBody(body));
  assert.equal(
    notes,
    [
      'New',
      '• Stay signed in after a cold start.',
      '• Pull to refresh on the activity list.',
      '',
      'Improved',
      '• Cut the cold start time by roughly a third.',
      '',
      'Fixed',
      '• Keep drafts when the network drops mid-save.',
    ].join('\n'),
  );
  // Nothing from the repository survives into the notes.
  assert.doesNotMatch(notes, /[#[\]()*`]|https?:|auth:|9f2c1ab/);
  // A chore is real work, but not news for a store page.
  assert.doesNotMatch(notes, /expo/i);
});

test('conventional commit subjects group the same way', () => {
  const items = parseCommits([
    'feat(home): show the unread count on the tab bar (#12)',
    'fix: stop the crash when a push arrives while locked',
    'perf(list): render long lists without dropping frames',
    'refactor(api): split the client into modules',
    'refactor(theme): use the system font everywhere [user-visible]',
    'chore(deps): bump react-native',
    'not a conventional subject',
  ]);
  assert.deepEqual(
    items.map((item) => [item.group, item.text]),
    [
      ['New', 'Show the unread count on the tab bar.'],
      ['Fixed', 'Stop the crash when a push arrives while locked.'],
      ['Improved', 'Render long lists without dropping frames.'],
      ['Other', 'Split the client into modules.'],
      ['Improved', 'Use the system font everywhere.'],
      ['Other', 'Bump react-native.'],
    ],
  );
});

test('an empty release still says something honest, per locale', async () => {
  assert.equal(renderNotes([]), 'Bug fixes and improvements.');
  const notes = await buildNotes({ items: [], locales: ['en-US', 'sv-SE'] });
  assert.deepEqual(notes, {
    'en-US': 'Bug fixes and improvements.',
    'sv-SE': 'Bug fixes and improvements.',
  });
});

// ---------- truncation ----------

test('text at the limit is untouched, and one character over is cut to fit', () => {
  const exact = 'a'.repeat(500);
  assert.equal(limitText(exact, 500), exact);

  const over = `${'word '.repeat(120)}tail`.trim();
  const cut = limitText(over, 500);
  assert.equal(cut.length <= 500, true);
  assert.equal(cut.endsWith(TRUNCATION_SUFFIX), true);
  // A word boundary is honoured, so the cut never lands mid-word.
  assert.equal(cut.slice(0, -TRUNCATION_SUFFIX.length).endsWith('word'), true);
});

test('a limit too small for the pointer hard-cuts instead of returning only a suffix', () => {
  assert.equal(limitText('hello world', 5), 'hello');
  assert.equal(
    limitText('hello world again friend', TRUNCATION_SUFFIX.length),
    'hello world again',
  );
  assert.equal(limitText('hello world', 0), '');
});

test('a single long word keeps the window rather than losing nearly all of it', () => {
  const text = `x ${'y'.repeat(600)}`;
  const cut = limitText(text, 500);
  assert.equal(cut.length, 500);
  assert.equal(cut.startsWith('x yyy'), true);
});

test('every store field is produced within its own limit', () => {
  const long = 'Something changed and here is a sentence about it. '.repeat(200);
  const notes = toStoreNotes({ 'en-US': long });
  assert.equal(notes['en-US'].play.length <= STORE_LIMITS.play, true);
  assert.equal(notes['en-US'].appstore.length <= STORE_LIMITS.appstore, true);
  assert.equal(notes['en-US'].testflight.length <= STORE_LIMITS.testflight, true);
  assert.equal(notes['en-US'].play.endsWith(TRUNCATION_SUFFIX), true);
});

// ---------- body section + changelog ----------

test('a "## Store notes" section is used verbatim when asked for', async () => {
  const section = extractStoreSection(body);
  assert.match(section, /^Signing in sticks now/);
  const notes = await buildNotes({ items: parseBody(body), locales: ['en-US'], verbatim: section });
  assert.equal(notes['en-US'], section);
  assert.equal(extractStoreSection('### Features\n\n* something'), '');
});

test('a verbatim section is final: the changelog is never appended to it', async () => {
  const items = parseBody(body);
  const notes = await buildNotes({
    items,
    locales: ['en-US'],
    verbatim: 'Reviewed prose.',
    includeChangelog: true,
  });
  assert.equal(notes['en-US'], 'Reviewed prose.');
});

test('--include-changelog appends the full grouped list, chores included', async () => {
  const items = parseBody(body);
  const changelog = renderChangelog(items);
  assert.match(changelog, /^Changelog\n/);
  assert.match(changelog, /Other: Bump expo to 57\.0\.20\./);

  const notes = await buildNotes({ items, locales: ['en-US'], includeChangelog: true });
  assert.equal(notes['en-US'], `${renderNotes(items)}\n\n${changelog}`);
});

// ---------- llm adapters ----------

// ---------- llm rewrite: validation and fallback ----------

// ---------- cli ----------

test('the cli writes store-notes.json and store-notes.txt into --out', () => {
  const out = tempDir();
  execFileSync(
    process.execPath,
    [script, '--from-body', path.join(fixtures, 'release-body.md'), '--out', out],
    {
      encoding: 'utf8',
      env: {
        ...process.env,
        STORE_NOTES_LLM_PROVIDER: '',
        STORE_NOTES_INCLUDE_CHANGELOG: '',
      },
    },
  );

  const notes = JSON.parse(readFileSync(path.join(out, 'store-notes.json'), 'utf8'));
  assert.deepEqual(Object.keys(notes), ['en-US']);
  assert.deepEqual(Object.keys(notes['en-US']).sort(), ['appstore', 'play', 'testflight']);
  assert.match(notes['en-US'].testflight, /^New\n• Stay signed in after a cold start\./);
  assert.equal(
    readFileSync(path.join(out, 'store-notes.txt'), 'utf8'),
    `${notes['en-US'].testflight}\n`,
  );
});

test('the cli prints json to stdout with --out - and honours --body-section', () => {
  const stdout = execFileSync(
    process.execPath,
    [
      script,
      '--from-body',
      path.join(fixtures, 'release-body.md'),
      '--body-section',
      '--locales',
      'en-US,sv-SE',
      '--out',
      '-',
    ],
    { encoding: 'utf8', env: { ...process.env, STORE_NOTES_LLM_PROVIDER: '' } },
  );
  const notes = JSON.parse(stdout);
  assert.deepEqual(Object.keys(notes), ['en-US', 'sv-SE']);
  assert.match(notes['en-US'].play, /^Signing in sticks now/);
  assert.equal(notes['sv-SE'].appstore, notes['en-US'].appstore);
});

// ---------- fix round 1: hygiene of a hand-written override ----------

test('a hand-written "## Store notes" override is cleaned, not trusted', () => {
  const section = [
    '## Store notes',
    '',
    'See the [full notes](https://example.com/notes) and PR #128 (9f2c1ab) **bold**.',
    '',
    '- Faster launch [ios]',
    '* ENG-42: fewer crashes',
  ].join('\n');
  const cleaned = cleanSection(extractStoreSection(section));
  assert.equal(
    cleaned,
    ['See the full notes and PR bold.', '', '• Faster launch ios', '• fewer crashes'].join('\n'),
  );
  assert.doesNotMatch(cleaned, /[#[\]*`<>]|https?:/);
});

// ---------- store notes on the release PR: markers and rules ----------

test('a section appended by the shared workflow ends at its end marker', () => {
  // The exact shape cd-beta leaves behind: the shared append mode wraps
  // the section in HTML-comment markers, and production reads it back.
  const body = [
    '## [0.6.1](https://example.com/compare/v0.6.0...v0.6.1) (2026-09-21)',
    '',
    '### Bug Fixes',
    '',
    '* fix one',
    '',
    '<!-- workflows:append:Store notes -->',
    '## Store notes',
    '',
    'Fixed',
    '• Close the alerts.',
    '<!-- /workflows:append:Store notes -->',
  ].join('\n');
  const cleaned = cleanSection(extractStoreSection(body));
  assert.equal(cleaned, 'Fixed\n• Close the alerts.');
  assert.doesNotMatch(cleaned, /!--/);
});

test('a section inside a release PR body ends at the footer rule', () => {
  const body = [
    ':robot: I have created a release *beep* *boop*',
    '---',
    '',
    '## [0.6.1](https://example.com/compare/v0.6.0...v0.6.1) (2026-09-21)',
    '',
    '<!-- workflows:append:Store notes -->',
    '## Store notes',
    '',
    'Fixed',
    '• Close the alerts.',
    '<!-- /workflows:append:Store notes -->',
    '',
    '---',
    'This PR was generated with Release Please.',
  ].join('\n');
  assert.equal(cleanSection(extractStoreSection(body)), 'Fixed\n• Close the alerts.');
});

test('a real release PR body yields its changelog and the section a previous run wrote', () => {
  const prBody = fixture('release-pr-body.md');
  const items = parseBody(prBody);
  assert.deepEqual(
    items.filter((item) => item.group === 'New').map((item) => item.text)[0],
    'Add the local half of the security gate.',
  );
  assert.equal(items.filter((item) => item.group === 'Fixed').length, 4);
  // The footer and the robot line are not changelog bullets.
  assert.equal(items.some((item) => /Release Please|beep/.test(item.text)), false);
  const section = cleanSection(extractStoreSection(prBody));
  assert.match(section, /^New\n• Add the local half of the security gate\./);
  assert.match(section, /• Keep Claude Code worktrees out of every tool's file walk\.$/);
  assert.doesNotMatch(section, /workflows:append|Release Please|---/);
});

test('a comment line inside a section is dropped, not shipped', () => {
  const body = ['## Store notes', '', 'New', '<!-- a note to self -->', '• Thing.'].join('\n');
  assert.equal(cleanSection(extractStoreSection(body)), 'New\n• Thing.');
});

test('the cli sends --body-section through the same filter', () => {
  const dir = tempDir();
  const file = path.join(dir, 'body.md');
  writeFileSync(
    file,
    [
      '### Features',
      '',
      '* **x:** thing',
      '',
      '## Store notes',
      '',
      'Read [more](https://x.dev/a) about PR #7 (9f2c1ab).',
    ].join('\n'),
  );
  const notes = JSON.parse(
    execFileSync(process.execPath, [script, '--from-body', file, '--body-section', '--out', '-'], {
      encoding: 'utf8',
      env: { ...process.env, STORE_NOTES_LLM_PROVIDER: '' },
    }),
  );
  assert.equal(notes['en-US'].testflight, 'Read more about PR.');
});

test('bracket tags, html and ticket keys never survive cleanText', () => {
  assert.equal(cleanText('fix: crash on launch [ios]'), 'Fix: crash on launch ios.');
  assert.equal(parseCommits(['fix: crash on launch [ios]'])[0].text, 'Crash on launch ios.');
  assert.equal(parseCommits(['feat: new tab bar [WIP] <b>x</b>'])[0].text, 'New tab bar WIP x.');
  // A tag broken open by another tag: the tag strip runs to a fixpoint, and
  // the bracket strip takes apart whatever is left, so no `<` or `>` ever
  // reaches a store.
  assert.equal(parseCommits(['feat: x <scr<b>ipt>alert(1)</script>'])[0].text, 'X iptalert(1).');
  assert.equal(parseCommits(['fix: JIRA-123 handle retry'])[0].text, 'Handle retry.');
});

test('a revert keeps the reverted change, not its header', () => {
  assert.deepEqual(parseCommits(['revert: feat(x): dark mode'])[0], {
    group: 'Other',
    text: 'Reverted dark mode.',
  });
});

test('a [user-visible] marker moves a body bullet out of Other', () => {
  const items = parseBody(
    ['### Miscellaneous Chores', '', '* **theme:** use the system font [user-visible]'].join('\n'),
  );
  assert.deepEqual(items, [{ group: 'Improved', text: 'Use the system font.' }]);
});

// ---------- fix round 1: llm validation ----------

// ---------- the prompt: the package's, then the app's addendum ----------

test('the shipped prompt template renders and states the output contract', () => {
  const template = loadPrompt();
  assert.equal(template, readFileSync(DEFAULT_PROMPT_FILE, 'utf8'));
  assert.match(template, /\{\{locales\}\}/);
  const rendered = renderPrompt(template, { locales: 'en-US', limit: TESTFLIGHT_LIMIT });
  assert.match(rendered, /\{"en-US": "\.\.\."\}/);
  assert.match(rendered, new RegExp(`At most ${TESTFLIGHT_LIMIT} characters`));
  assert.doesNotMatch(rendered, /\{\{/);
});

test("the app's addendum follows the package's prompt after a blank line", () => {
  assert.equal(composePrompt('Base.\n', '\n## Product\n\nAcme.\n'), 'Base.\n\n## Product\n\nAcme.');
  assert.equal(composePrompt('Base.', ''), 'Base.');
  assert.equal(composePrompt('Base.', undefined), 'Base.');
  assert.equal(composePrompt('', 'Only the app.'), 'Only the app.');
  assert.equal(composePrompt('  ', null), '');
});

test("main reads the app's store-notes.prompt.md from its working directory", async () => {
  const app = tempDir();
  writeFileSync(path.join(app, APP_PROMPT_FILE), '## Product\n\n- **Name:** Acme for {{locales}}\n');
  const seen = [];
  const rewrite = async (request) => {
    seen.push(request.prompt);
    return null;
  };
  const env = { STORE_NOTES_LLM_PROVIDER: 'anthropic' };
  const withApp = await runMain(['--from-body', releaseBody, '--locales', 'en-US'], { cwd: app, env, rewrite });
  const without = await runMain(['--from-body', releaseBody, '--locales', 'en-US'], { cwd: tempDir(), env, rewrite });
  assert.equal(withApp.code, 0);
  assert.equal(without.code, 0);
  const base = loadPrompt().trim();
  assert.equal(seen[0], `${base}\n\n## Product\n\n- **Name:** Acme for {{locales}}`);
  assert.equal(seen[1], base);
  // The addendum is rendered with the package's prompt, placeholders and all.
  assert.match(renderPrompt(seen[0], { locales: 'en-US', limit: TESTFLIGHT_LIMIT }), /Acme for en-US$/);
});

test("main finds the app's locales and commits in its working directory, not the package's", async () => {
  const app = tempDir();
  for (const name of ['de-DE', 'en-US', 'review_information']) {
    mkdirSync(path.join(app, 'fastlane', 'metadata', 'ios', name), { recursive: true });
  }
  const git = (...args) => execFileSync('git', args, { cwd: app, stdio: 'pipe' });
  git('init', '--quiet', '--initial-branch=main');
  git('config', 'user.email', 'test@example.com');
  git('config', 'user.name', 'Test');
  git('config', 'commit.gpgsign', 'false');
  git('commit', '--quiet', '--allow-empty', '-m', 'feat: only in the app');
  const { code, out } = await runMain(['--from-commits'], { cwd: app });
  assert.equal(code, 0);
  const notes = JSON.parse(out);
  assert.deepEqual(Object.keys(notes), ['de-DE', 'en-US']);
  assert.equal(notes['de-DE'].play, 'New\n• Only in the app.');
});

// ---------- fix round 1: cli surface ----------

test('a flag without a value, and two sources at once, both fail loudly', () => {
  assert.throws(() => parseArgs(['--locales']), /--locales needs a value/);
  assert.throws(() => parseArgs(['--from-body', 'a.md', '--from-commits']), /mutually exclusive/);
  assert.throws(() => parseArgs([]), /is required/);
  assert.throws(() => parseArgs(['--nope']), /unknown argument/);
  assert.deepEqual(parseArgs(['--from-commits', 'v1..HEAD']).range, 'v1..HEAD');
  assert.equal(parseArgs(['--from-commits']).range, '');
  assert.equal(parseArgs(['--from-commits', '--include-changelog']).includeChangelog, true);
  assert.equal(parseArgs(['--from-commits']).fastlaneDirectory, 'fastlane');
  assert.equal(parseArgs(['--from-commits', '--fastlane-directory', 'mobile/fastlane']).fastlaneDirectory, 'mobile/fastlane');
  assert.throws(() => parseArgs(['--from-commits', '--fastlane-directory']), /--fastlane-directory needs a value/);
});

test('the locales are discovered under the fastlane directory the caller names', () => {
  // A bare app may keep its Fastfile in mobile/fastlane (the fastlane-directory
  // workflow input); its metadata/ios is then the one that names the locales.
  const cwd = tempDir();
  mkdirSync(path.join(cwd, 'mobile', 'fastlane', 'metadata', 'ios', 'de-DE'), { recursive: true });
  mkdirSync(path.join(cwd, 'fastlane', 'metadata', 'ios', 'sv-SE'), { recursive: true });
  const none = { locales: [] };
  assert.deepEqual(resolveLocales({ ...none, fastlaneDirectory: 'mobile/fastlane' }, {}, cwd), ['de-DE']);
  assert.deepEqual(resolveLocales({ ...none, fastlaneDirectory: 'fastlane' }, {}, cwd), ['sv-SE']);
  // Without the option (a caller that builds options itself), fastlane/ is read.
  assert.deepEqual(resolveLocales(none, {}, cwd), ['sv-SE']);
});

test('locales come from the ios metadata directories, ignoring the non-locales', () => {
  const dir = tempDir();
  for (const name of ['en-US', 'fr-FR', 'review_information', 'screenshots']) {
    mkdirSync(path.join(dir, name));
  }
  assert.deepEqual(discoverLocales(dir), ['en-US', 'fr-FR']);
  assert.deepEqual(discoverLocales(path.join(dir, 'nope')), ['en-US']);
});

test('STORE_NOTES_LOCALES is honoured, below --locales and above discovery', () => {
  // build-prepare exports it for its `store-notes-locales` input; before this the
  // input was plumbed through the whole workflow and then ignored.
  const flag = { locales: ['sv-SE'] };
  const none = { locales: [] };
  assert.deepEqual(resolveLocales(flag, { STORE_NOTES_LOCALES: 'de,fr-FR' }), ['sv-SE']);
  assert.deepEqual(resolveLocales(none, { STORE_NOTES_LOCALES: 'de,fr-FR' }), ['de', 'fr-FR']);
  assert.deepEqual(resolveLocales(none, { STORE_NOTES_LOCALES: ' de , fr-FR ,' }), ['de', 'fr-FR']);
  // An empty or absent value must not produce an empty locale list, which would
  // write a store-notes.json with no locales in it at all.
  assert.deepEqual(resolveLocales(none, { STORE_NOTES_LOCALES: '' }), discoverLocales());
  assert.deepEqual(resolveLocales(none, {}), discoverLocales());
});

test('--help prints the usage and exits 0 without rendering anything', () => {
  const stdout = execFileSync('node', [script, '--help'], { encoding: 'utf8' });
  assert.match(stdout, /^Store notes for a build/);
  assert.match(stdout, /^ {2}gen-store-notes \(--from-body FILE/m);
  assert.match(stdout, /--from-commits/);
  assert.match(stdout, /--locales/);
});

test('commit subjects default to the range since the last v* tag', () => {
  const repo = tempDir();
  const git = (...args) => execFileSync('git', args, { cwd: repo, stdio: 'pipe' });
  git('init', '--quiet', '--initial-branch=main');
  git('config', 'user.email', 'test@example.com');
  git('config', 'user.name', 'Test');
  git('config', 'commit.gpgsign', 'false');
  git('commit', '--quiet', '--allow-empty', '-m', 'feat: one');
  // No tag yet: everything on HEAD is the release.
  assert.deepEqual(commitSubjects('', repo), ['feat: one']);
  git('tag', 'v1.0.0');
  git('commit', '--quiet', '--allow-empty', '-m', 'fix: two');
  assert.deepEqual(commitSubjects('', repo), ['fix: two']);
  assert.deepEqual(commitSubjects('v1.0.0..HEAD', repo), ['fix: two']);
});

test('STORE_NOTES_INCLUDE_CHANGELOG=true appends the changelog through the cli', () => {
  const notes = JSON.parse(
    execFileSync(
      process.execPath,
      [script, '--from-body', path.join(fixtures, 'release-body.md'), '--out', '-'],
      {
        encoding: 'utf8',
        env: {
          ...process.env,
          STORE_NOTES_LLM_PROVIDER: '',
          STORE_NOTES_INCLUDE_CHANGELOG: 'true',
        },
      },
    ),
  );
  assert.match(notes['en-US'].testflight, /\nChangelog\nNew: Stay signed in/);
});

test('store-notes.txt falls back to the first locale when en-US is not requested', () => {
  const out = tempDir();
  execFileSync(
    process.execPath,
    [
      script,
      '--from-body',
      path.join(fixtures, 'release-body.md'),
      '--locales',
      'sv-SE',
      '--out',
      out,
    ],
    { encoding: 'utf8', env: { ...process.env, STORE_NOTES_LLM_PROVIDER: '' } },
  );
  const notes = JSON.parse(readFileSync(path.join(out, 'store-notes.json'), 'utf8'));
  assert.deepEqual(Object.keys(notes), ['sv-SE']);
  assert.equal(
    readFileSync(path.join(out, 'store-notes.txt'), 'utf8'),
    `${notes['sv-SE'].testflight}\n`,
  );
});

// ---------- main, in process ----------

/** Runs `main` with its output captured; returns the exit code and both streams. */
async function runMain(argv, io = {}) {
  const out = [];
  const err = [];
  const code = await main(argv, {
    env: { STORE_NOTES_LLM_PROVIDER: '' },
    write: (text) => out.push(text),
    error: (line) => err.push(line),
    ...io,
  });
  return { code, out: out.join(''), err };
}

const releaseBody = path.join(fixtures, 'release-body.md');

test('main prints the usage for -h and exits 0', async () => {
  const { code, out, err } = await runMain(['-h']);
  assert.equal(code, 0);
  assert.match(out, /^Store notes for a build/);
  assert.match(out, /^ {2}--help, -h {12}this text$/m);
  assert.match(out, /^ {2}TAG=v1.4.0 gen-store-notes --preview$/m);
  assert.deepEqual(err, []);
});

test('main resolves --from-body against cwd and writes both files into --out', async () => {
  const out = tempDir();
  const { code, err } = await runMain(
    ['--from-body', 'release-body.md', '--out', out, '--locales', 'en-US'],
    { cwd: fixtures },
  );
  assert.equal(code, 0);
  assert.deepEqual(err, [`store notes written to ${out} (en-US)`]);
  const notes = JSON.parse(readFileSync(path.join(out, 'store-notes.json'), 'utf8'));
  assert.equal(
    readFileSync(path.join(out, 'store-notes.txt'), 'utf8'),
    `${notes['en-US'].testflight}\n`,
  );
});

test('main takes the locales from the environment it is given', async () => {
  const { code, out } = await runMain(['--from-body', releaseBody], {
    env: { STORE_NOTES_LOCALES: 'de,fr-FR' },
  });
  assert.equal(code, 0);
  assert.deepEqual(Object.keys(JSON.parse(out)), ['de', 'fr-FR']);
});

test('main renders an empty commit range from --from-commits', async () => {
  const { code, out } = await runMain(['--from-commits', 'HEAD..HEAD', '--locales', 'en-US']);
  assert.equal(code, 0);
  assert.equal(JSON.parse(out)['en-US'].testflight, renderNotes([]));
});

test('main hands the provider and model from its environment to the rewrite', async () => {
  const seen = [];
  const { code, out } = await runMain(['--from-body', releaseBody, '--locales', 'en-US'], {
    env: { STORE_NOTES_LLM_PROVIDER: 'openai', STORE_NOTES_LLM_MODEL: 'gpt-5-mini' },
    rewrite: async (request) => {
      seen.push(request);
      return { 'en-US': 'Rewritten.' };
    },
  });
  assert.equal(code, 0);
  assert.equal(seen[0].provider, 'openai');
  assert.equal(seen[0].model, 'gpt-5-mini');
  assert.equal(JSON.parse(out)['en-US'].play, 'Rewritten.');
});

/** main with the real rewrite and adapter, stopping only at the network. */
async function mainRequest(extraEnv) {
  const calls = [];
  const result = await withEnv(
    { OPENAI_API_KEY: 'sk-test', OPENAI_BASE_URL: 'https://models.github.ai/inference' },
    () =>
      withFetch(stubFetch(JSON.parse(fixture('openai-response.json')), calls), () =>
        runMain(['--from-body', releaseBody, '--locales', 'en-US'], {
          env: { STORE_NOTES_LLM_PROVIDER: 'openai', ...extraEnv },
        }),
      ),
  );
  return { ...result, sent: calls.map((call) => JSON.parse(call.init.body)) };
}

test('effort none and a null extra parameter from the environment shape the request', async () => {
  const { code, out, err, sent } = await mainRequest({
    STORE_NOTES_LLM_EFFORT: 'none',
    STORE_NOTES_LLM_EXTRA_PARAMS: '{"response_format": null}',
  });
  assert.equal(code, 0);
  assert.deepEqual(err, []);
  assert.equal(sent.length, 1);
  assert.equal('reasoning_effort' in sent[0], false);
  assert.equal('response_format' in sent[0], false);
  assert.equal(sent[0].max_tokens, maxTokensFor(['en-US']));
  assert.match(JSON.parse(out)['en-US'].play, /^You stay signed in/);
});

test('an unset effort from the environment thinks at max, with room to think', async () => {
  const { code, sent } = await mainRequest({});
  assert.equal(code, 0);
  assert.equal(sent[0].reasoning_effort, 'high');
  assert.deepEqual(sent[0].response_format, { type: 'json_object' });
  assert.equal(sent[0].max_tokens, maxTokensFor(['en-US'], 'max'));
});

test('an effort outside the vocabulary fails the draft and names the variable', async () => {
  const { code, err, sent } = await mainRequest({ STORE_NOTES_LLM_EFFORT: 'off' });
  assert.equal(code, 1);
  assert.match(err[0], /STORE_NOTES_LLM_EFFORT: expected one of none, low, medium, high, max/);
  assert.equal(sent.length, 0);
});

test('a rewrite that cannot be trusted leaves the deterministic prose', async () => {
  const items = parseBody(body);
  const notes = await buildNotes({
    items,
    locales: ['en-US'],
    provider: 'anthropic',
    rewrite: async () => null,
  });
  assert.equal(notes['en-US'], renderNotes(items));
});

test('main reports a bad argument on stderr and exits 1', async () => {
  const { code, out, err } = await runMain(['--nope']);
  assert.equal(code, 1);
  assert.equal(out, '');
  assert.deepEqual(err, ['unknown argument: --nope']);
});

test('main reports a failure that is not an Error as itself', async () => {
  const { code, err } = await runMain(['--from-body', releaseBody, '--locales', 'en-US'], {
    env: { STORE_NOTES_LLM_PROVIDER: 'anthropic' },
    rewrite: async () => {
      throw 'provider exploded';
    },
  });
  assert.equal(code, 1);
  assert.deepEqual(err, ['provider exploded']);
});

test('the cli exits 1 with the reason on a bad argument', () => {
  const result = spawnSync(process.execPath, [script, '--nope'], {
    encoding: 'utf8',
    env: { ...process.env, STORE_NOTES_LLM_PROVIDER: '' },
  });
  assert.equal(result.status, 1);
  assert.equal(result.stderr, 'unknown argument: --nope\n');
});

// ---------- llm adapters: every failure shape ----------

// ---------- edge cases of the deterministic pipeline ----------

test('a line with nothing left after cleaning is dropped, not rendered empty', () => {
  assert.equal(cleanText(''), '');
  assert.equal(cleanText('Done!'), 'Done!');
  assert.deepEqual(parseBody('### Features\n\n* (#12)\n* real thing'), [
    { group: 'New', text: 'Real thing.' },
  ]);
  assert.deepEqual(parseCommits(['', '  ', 'fix: (#12)']), []);
});

test('a revert of a subject that is not conventional keeps the subject', () => {
  assert.deepEqual(parseCommits(['revert: something plain']), [
    { group: 'Other', text: 'Reverted something plain.' },
  ]);
});

test('no items means no changelog, and a missing prompt file is an empty prompt', () => {
  assert.equal(renderChangelog([]), '');
  assert.equal(loadPrompt(path.join(tempDir(), 'absent.prompt.md')), '');
});

test('locale discovery falls back to en-US when the metadata has no locale directory', () => {
  const dir = tempDir();
  mkdirSync(path.join(dir, 'review_information'));
  assert.deepEqual(discoverLocales(dir), ['en-US']);
  assert.deepEqual(discoverLocales(path.join(dir, 'absent')), ['en-US']);
});

test('the package publishes the program and the prompt it reads', () => {
  const pkg = JSON.parse(readFileSync(path.join(here, 'package.json'), 'utf8'));
  assert.equal(pkg.bin['gen-store-notes'], './bin/gen-store-notes.mjs');
  assert.equal(pkg.exports['./gen-store-notes'], undefined, 'a program is run, not imported');
  assert.ok(pkg.files.includes(path.basename(DEFAULT_PROMPT_FILE)), 'the default prompt is not published');
  assert.equal(path.dirname(DEFAULT_PROMPT_FILE), here);
});

// ---------- --tag, --pr and --preview: the body from GitHub ----------

/** A stand-in for execFileSync that answers `gh` with `body`, recording each call. */
function fakeGh(calls, answer = () => fixture('release-body.md')) {
  return (command, args, options) => {
    calls.push({ command, args, cwd: options.cwd });
    return answer(args);
  };
}

/** An error shaped like execFileSync's when the command ran and failed. */
function ghFailure(stderr, message = 'Command failed: gh') {
  return () => {
    throw Object.assign(new Error(message), { status: 1, stderr });
  };
}

test('--tag, --pr and --preview are sources, and only one source may be given', () => {
  assert.equal(parseArgs(['--tag', 'v1.4.0']).tag, 'v1.4.0');
  assert.equal(parseArgs(['--pr', '67']).pr, '67');
  assert.equal(parseArgs(['--preview']).preview, true);
  assert.equal(parseArgs(['--preview', '--from-commits']).fromCommits, true);
  assert.throws(() => parseArgs(['--tag', 'v1', '--pr', '2']), /^Error: --tag and --pr are mutually exclusive/);
  assert.throws(() => parseArgs(['--from-commits', '--tag', 'v1']), /--from-commits and --tag are mutually exclusive/);
  assert.throws(() => parseArgs(['--pr']), /--pr needs a value/);
  assert.throws(() => parseArgs(['--locales', 'en-US']), /--tag TAG, --pr N or --preview is required/);
});

test('--preview takes TAG, then PR, from the environment, and otherwise the commits', () => {
  const preview = parseArgs(['--preview']);
  const { tag, pr, fromCommits: none, bodySection } = resolveSource(preview, { TAG: ' v1.4.0 ' });
  assert.deepEqual({ tag, pr, none, bodySection }, { tag: 'v1.4.0', pr: '', none: false, bodySection: true });
  const fromPr = resolveSource(preview, { PR: '67', TAG: '' });
  assert.equal(fromPr.pr, '67');
  assert.equal(fromPr.bodySection, true);
  const fromCommits = resolveSource(preview, {});
  assert.equal(fromCommits.fromCommits, true);
  assert.equal(fromCommits.bodySection, false);
  assert.throws(() => resolveSource(preview, { TAG: 'v1', PR: '2' }), /^Error: TAG and PR are mutually exclusive/);
  assert.throws(() => resolveSource(preview, { PR: 'main' }), /^Error: PR takes a pull request number, got "main"$/);
  // The options it was given are left as they were.
  assert.equal(preview.tag, '');
});

test('a flag wins over the environment, and without --preview the environment is never read', () => {
  const flagged = resolveSource(parseArgs(['--preview', '--pr', '5']), { TAG: 'v9', PR: '9' });
  assert.deepEqual([flagged.tag, flagged.pr], ['', '5']);
  const commits = resolveSource(parseArgs(['--from-commits']), { TAG: 'v9' });
  assert.deepEqual([commits.tag, commits.fromCommits, commits.bodySection], ['', true, false]);
  const body = resolveSource(parseArgs(['--from-body', 'a.md']));
  assert.deepEqual([body.fromBody, body.bodySection], ['a.md', false]);
  assert.throws(() => resolveSource(parseArgs(['--pr', '0'])), /^Error: --pr takes a pull request number, got "0"$/);
});

test('fetchBody asks gh for the release or the pull request body, in the app directory', () => {
  const calls = [];
  assert.equal(fetchBody({ tag: 'v1.4.0' }, { cwd: '/app', exec: fakeGh(calls) }), fixture('release-body.md'));
  fetchBody({ pr: '67' }, { cwd: '/app', exec: fakeGh(calls) });
  assert.deepEqual(calls, [
    { command: 'gh', args: ['release', 'view', 'v1.4.0', '--json', 'body', '-q', '.body'], cwd: '/app' },
    { command: 'gh', args: ['pr', 'view', '67', '--json', 'body', '-q', '.body'], cwd: '/app' },
  ]);
});

test('fetchBody names what failed: a tag or pull request that is not there, or an empty body', () => {
  assert.throws(
    () => fetchBody({ tag: 'v9.9.9' }, { exec: ghFailure('release not found\nmore detail\n') }),
    /^Error: gh release view v9\.9\.9 failed: release not found$/,
  );
  assert.throws(
    () => fetchBody({ pr: '404' }, { exec: ghFailure('', 'Command failed: gh pr view 404') }),
    /^Error: gh pr view 404 failed: Command failed: gh pr view 404$/,
  );
  assert.throws(() => fetchBody({ tag: 'v1' }, { exec: () => ' \n' }), /^Error: the body of release v1 is empty$/);
  assert.throws(() => fetchBody({ pr: '3' }, { exec: () => '' }), /^Error: the body of pull request 3 is empty$/);
});

test('fetchBody says gh is missing when it is not on PATH', async () => {
  await withEnv({ PATH: '/nonexistent' }, async () => {
    assert.throws(() => fetchBody({ tag: 'v1' }), /^Error: gh is not installed: --tag and --pr read the body/);
  });
  const missing = () => {
    throw Object.assign(new Error('spawnSync gh ENOENT'), { code: 'ENOENT' });
  };
  assert.throws(() => fetchBody({ pr: '1' }, { exec: missing }), /gh is not installed/);
});

test("main --tag previews that release's reviewed Store notes section", async () => {
  const calls = [];
  const { code, out, err } = await runMain(['--tag', 'v1.4.0', '--locales', 'en-US'], {
    cwd: fixtures,
    exec: fakeGh(calls),
  });
  assert.equal(code, 0);
  assert.deepEqual(err, []);
  assert.equal(calls[0].cwd, fixtures);
  assert.match(JSON.parse(out)['en-US'].play, /^Signing in sticks now/);
});

test("main --preview with PR in its environment reads that pull request's body", async () => {
  const calls = [];
  const { code, out } = await runMain(['--preview', '--locales', 'en-US'], {
    env: { PR: '67' },
    exec: fakeGh(calls, () => fixture('release-pr-body.md')),
  });
  assert.equal(code, 0);
  assert.deepEqual(calls[0].args.slice(0, 3), ['pr', 'view', '67']);
  assert.match(JSON.parse(out)['en-US'].testflight, /^New\n• Add the local half of the security gate\./);
});

test('main --preview with neither TAG nor PR previews the commits and calls no gh', async () => {
  const { code, out } = await runMain(['--preview', '--locales', 'en-US'], {
    exec: () => {
      throw new Error('gh must not be called');
    },
  });
  assert.equal(code, 0);
  assert.ok(JSON.parse(out)['en-US'].testflight.length > 0);
});

test('main reports a gh failure on stderr and exits 1', async () => {
  const { code, out, err } = await runMain(['--preview'], {
    env: { TAG: 'v0.0.0' },
    exec: ghFailure('release not found\n'),
  });
  assert.equal(code, 1);
  assert.equal(out, '');
  assert.deepEqual(err, ['gh release view v0.0.0 failed: release not found']);
});
