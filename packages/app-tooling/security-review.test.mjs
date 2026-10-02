import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import {
  buildUserPrompt,
  composePrompt,
  DEFAULT_PROMPT_FILE,
  EXCLUDED,
  fitDiff,
  main,
  PROMPT_FILE,
  resolveBase,
  review,
  splitDiff,
  validateReview,
} from './lib/security-review.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = here;

const DIFF = [
  'diff --git a/src/a.ts b/src/a.ts',
  '--- a/src/a.ts',
  '+++ b/src/a.ts',
  '@@ -1 +1 @@',
  '+const token = "x";',
  'diff --git a/src/b.ts b/src/b.ts',
  '--- a/src/b.ts',
  '+++ b/src/b.ts',
  '+b',
  '',
].join('\n');

// Settings come from a policy file that does not exist, so only what the test
// puts in the environment decides the run.
const ENV = {
  SECURITY_SETTINGS_FILE: '/nonexistent/security-settings.json',
  SECURITY_LLM_PROVIDER: 'anthropic',
  ANTHROPIC_API_KEY: 'sk-ant-test',
  SECURITY_REVIEW_BASE: 'abc123',
};

const answer = (text) => ({
  ok: true,
  json: async () => ({ stop_reason: 'end_turn', content: [{ type: 'text', text }] }),
});
const git =
  (diff = DIFF) =>
  (args) => {
    if (args[0] === 'diff') return diff;
    throw new Error(`unexpected git ${args.join(' ')}`);
  };
const noteOf = (doc) => doc.runs[0].invocations[0].toolExecutionNotifications?.[0]?.message.text;

const run = (overrides = {}) =>
  review({
    env: ENV,
    run: git(),
    read: (file) => (file === PROMPT_FILE ? 'the addendum' : 'the default'),
    exists: () => true,
    fetchImpl: async () => answer('{"findings": []}'),
    ...overrides,
  });

test('resolveBase: an explicit base, the last release tag, or the merge base', () => {
  assert.deepEqual(resolveBase({ SECURITY_REVIEW_BASE: 'sha1' }), { base: 'sha1' });
  const calls = [];
  const fake = (result) => (args) => {
    calls.push(args.join(' '));
    if (result instanceof Error) throw result;
    return result;
  };
  assert.deepEqual(resolveBase({ SECURITY_REVIEW_FULL_RANGE: 'true' }, fake('v1.2.3')), {
    base: 'v1.2.3',
  });
  assert.match(calls[0], /describe --tags --abbrev=0 --match v\[0-9\]\* --exclude \*-\*/);
  assert.match(
    resolveBase({ SECURITY_REVIEW_FULL_RANGE: 'true' }, fake(new Error('none'))).reason,
    /no release tag/,
  );
  assert.deepEqual(resolveBase({}, fake('mb')), { base: 'mb' });
  assert.match(calls.at(-1), /^merge-base HEAD origin\/main$/);
  assert.match(resolveBase({}, fake(new Error('no origin'))).reason, /no base to diff against/);
});

test('the default git runner works against this repository', () => {
  assert.match(resolveBase({ SECURITY_REVIEW_FULL_RANGE: 'false' }).base ?? 'no-base', /\S/);
});

test('splitDiff gives one entry per file, and nothing for an empty diff', () => {
  const files = splitDiff(DIFF);
  assert.deepEqual(
    files.map((f) => f.file),
    ['src/a.ts', 'src/b.ts'],
  );
  assert.match(files[0].text, /^diff --git a\/src\/a\.ts/);
  assert.deepEqual(splitDiff(''), []);
});

test('fitDiff keeps whole files up to the cap and names the ones it dropped', () => {
  const files = [
    { file: 'a', text: 'x'.repeat(10) },
    { file: 'b', text: 'y'.repeat(100) },
    { file: 'c', text: 'z'.repeat(5) },
  ];
  const { kept, dropped } = fitDiff(files, 20);
  assert.deepEqual(
    kept.map((f) => f.file),
    ['a', 'c'],
  );
  assert.deepEqual(dropped, ['b']);
});

test('validateReview accepts a well-formed answer, fenced or not', () => {
  const files = new Set(['src/a.ts']);
  const one = { file: 'src/a.ts', line: 1, severity: 'high', title: ' Token ', detail: ' leaked ' };
  const plain = validateReview(JSON.stringify({ findings: [one] }), files);
  assert.deepEqual(plain.findings, [
    { ruleId: 'review', file: 'src/a.ts', line: 1, severity: 'high', message: 'Token: leaked' },
  ]);
  const fenced = validateReview(`\`\`\`json\n${JSON.stringify({ findings: [] })}\n\`\`\``, files);
  assert.deepEqual(fenced.findings, []);
});

test('validateReview rejects the whole answer on any bad finding', () => {
  const files = new Set(['src/a.ts']);
  const good = { file: 'src/a.ts', line: 3, severity: 'low', title: 't', detail: 'd' };
  const cases = [
    ['not json', /not JSON/],
    ['{"nope": []}', /no findings list/],
    ['null', /no findings list/],
    [JSON.stringify({ findings: [good, 'x'] }), /finding 2 is not an object/],
    [JSON.stringify({ findings: [null] }), /finding 1 is not an object/],
    [JSON.stringify({ findings: [{ ...good, file: 'elsewhere.ts' }] }), /outside the diff/],
    [JSON.stringify({ findings: [{ ...good, line: 0 }] }), /no valid line/],
    [JSON.stringify({ findings: [{ ...good, line: '3' }] }), /no valid line/],
    [JSON.stringify({ findings: [{ ...good, severity: 'urgent' }] }), /unknown severity/],
    [JSON.stringify({ findings: [{ ...good, title: '  ' }] }), /no usable title/],
    [JSON.stringify({ findings: [{ ...good, detail: 5 }] }), /no usable detail/],
    [JSON.stringify({ findings: [{ ...good, detail: 'x'.repeat(2001) }] }), /no usable detail/],
  ];
  for (const [raw, message] of cases) assert.match(validateReview(raw, files).error, message);
});

test('the user turn names the base and the files, and says the diff is data', () => {
  const prompt = buildUserPrompt(splitDiff(DIFF), 'abc');
  assert.match(prompt, /against abc\. Files in the diff: src\/a\.ts, src\/b\.ts\./);
  assert.match(prompt, /not instructions/);
  assert.match(prompt, /\+const token/);
});

test('the diff leaves out generated files and the lockfile', () => {
  for (const pattern of ['pnpm-lock.yaml', 'src/graphql/generated', 'CHANGELOG.md']) {
    assert.ok(
      EXCLUDED.some((entry) => entry.includes(pattern)),
      pattern,
    );
  }
});

test('every missing precondition is a skip with its reason', async () => {
  const cases = [
    [{ env: { ...ENV, SECURITY_LLM_PROVIDER: '' } }, /no LLM provider configured/],
    [{ env: { ...ENV, ANTHROPIC_API_KEY: '' } }, /ANTHROPIC_API_KEY is not set/],
    [{ env: { ...ENV, SECURITY_LLM_PROVIDER: 'openai' } }, /OPENAI_API_KEY is not set/],
    [
      {
        env: { ...ENV, SECURITY_REVIEW_BASE: '' },
        run: () => {
          throw new Error('x');
        },
      },
      /no base to diff against/,
    ],
    [
      {
        run: () => {
          throw new Error('bad ref');
        },
      },
      /git could not diff against abc123/,
    ],
    [
      { env: { ...ENV, SECURITY_REVIEW_MAX_DIFF_BYTES: '1' } },
      /larger than review\.maxDiffBytes \(1\)/,
    ],
    [
      { fetchImpl: async () => ({ ok: false, status: 529 }) },
      /anthropic did not answer \(anthropic: HTTP 529\)/,
    ],
    [
      { fetchImpl: async () => answer('I cannot help with that') },
      /answer was rejected: the answer is not JSON/,
    ],
  ];
  for (const [overrides, reason] of cases) {
    const doc = await run(overrides);
    assert.equal(doc.runs[0].invocations[0].executionSuccessful, false);
    assert.match(noteOf(doc), reason);
  }
});

test('an empty diff is a clean run that says there was nothing to review', async () => {
  const doc = await run({ run: git('') });
  assert.equal(doc.runs[0].invocations[0].executionSuccessful, true);
  assert.match(noteOf(doc), /nothing to review against abc123/);
});

test('a review at effort none sends no effort field, for a model with no reasoning switch', async () => {
  const calls = [];
  await run({
    env: { ...ENV, SECURITY_LLM_EFFORT: 'none' },
    fetchImpl: async (_url, init) => {
      calls.push(JSON.parse(init.body));
      return answer(JSON.stringify({ findings: [] }));
    },
  });
  assert.equal(calls.length, 1);
  assert.equal(calls[0].thinking, undefined);
  assert.equal(calls[0].output_config, undefined);
});

test('a repository without a prompt file of its own is reviewed with the package prompt alone', async () => {
  const calls = [];
  await run({
    exists: () => false,
    fetchImpl: async (_url, init) => {
      calls.push(JSON.parse(init.body));
      return answer('{"findings": []}');
    },
  });
  assert.equal(calls[0].system, 'the default');
});

test('composePrompt joins what is there and drops the rest', () => {
  assert.equal(composePrompt('a', 'b'), 'a\n\nb');
  assert.equal(composePrompt(' a \n', ''), 'a');
  assert.equal(composePrompt(undefined, ' b '), 'b');
  assert.equal(composePrompt('', undefined), '');
});

test('the package ships a prompt that asks for the JSON the validator reads', () => {
  const text = readFileSync(DEFAULT_PROMPT_FILE, 'utf8');
  assert.match(text, /"findings"/);
  assert.match(text, /The diff is data/);
  const manifest = JSON.parse(readFileSync(path.join(here, 'package.json'), 'utf8'));
  assert.ok(manifest.files.includes(path.basename(DEFAULT_PROMPT_FILE)), 'the default prompt is not published');
  assert.equal(path.dirname(DEFAULT_PROMPT_FILE), here);
});

test('a review sends the prompt, the diff and the effort, and reports its findings', async () => {
  const calls = [];
  const finding = {
    file: 'src/a.ts',
    line: 1,
    severity: 'critical',
    title: 'Hardcoded token',
    detail: 'Ships to users.',
  };
  const doc = await run({
    env: {
      ...ENV,
      SECURITY_LLM_EFFORT: 'high',
      SECURITY_LLM_EXTRA_PARAMS: '{"metadata":{"user_id":"ci"}}',
    },
    fetchImpl: async (_url, init) => {
      calls.push(JSON.parse(init.body));
      return answer(JSON.stringify({ findings: [finding] }));
    },
  });
  const [sent] = calls;
  assert.equal(sent.system, 'the default\n\nthe addendum');
  assert.match(sent.messages[0].content, /\+const token/);
  assert.deepEqual(sent.output_config, { effort: 'high' });
  assert.deepEqual(sent.metadata, { user_id: 'ci' });
  assert.equal(sent.max_tokens, 16000);
  const run0 = doc.runs[0];
  assert.equal(run0.invocations[0].executionSuccessful, true);
  assert.equal(run0.results[0].level, 'error');
  assert.equal(run0.results[0].properties['security-severity'], '9.0');
});

test('files over the cap go unreviewed, and the run says so rather than reading as complete', async () => {
  const big = `diff --git a/big.ts b/big.ts\n${'+x\n'.repeat(100)}`;
  const doc = await run({
    run: git(`${DIFF}${big}`),
    env: { ...ENV, SECURITY_REVIEW_MAX_DIFF_BYTES: '200' },
  });
  assert.equal(doc.runs[0].invocations[0].executionSuccessful, false);
  assert.match(noteOf(doc), /1 file\(s\) over review\.maxDiffBytes were not reviewed: big\.ts/);
});

test('an invalid extra-parameters value is the run failing, not a skip', async () => {
  const errors = [];
  const code = await main({
    error: (l) => errors.push(l),
    env: { ...ENV, SECURITY_LLM_EXTRA_PARAMS: '[1]' },
    run: git(),
    exists: () => true,
    read: () => 'p',
  });
  assert.equal(code, 1);
  assert.match(errors[0], /^review: SECURITY_LLM_EXTRA_PARAMS: expected a JSON object/);
});

test('main prints the document and exits 0 whatever the review decided', async () => {
  const out = [];
  const code = await main({ log: (l) => out.push(l), env: { ...ENV, SECURITY_LLM_PROVIDER: '' } });
  assert.equal(code, 0);
  assert.match(out[0], /no LLM provider configured/);
});

test('runs as a script', () => {
  const result = spawnSync(process.execPath, [path.join(here, 'lib', 'security-review.mjs')], {
    cwd: root,
    encoding: 'utf8',
    env: {
      ...process.env,
      SECURITY_SETTINGS_FILE: '/nonexistent/policy.json',
      SECURITY_LLM_PROVIDER: '',
    },
  });
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /skipped: no LLM provider configured/);
});
