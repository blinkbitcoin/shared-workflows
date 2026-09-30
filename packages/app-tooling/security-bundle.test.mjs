import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import {
  bundleUri,
  findingsFor,
  main,
  printableRuns,
  privateNames,
  readOptional,
  SECRET_SHAPES,
} from './lib/security-bundle.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const OPTIONS = { names: ['APP_VARIANT'], hosts: [], cleartextHosts: ['localhost'] };
const rules = (findings) => findings.map((f) => f.ruleId);

test('printableRuns finds the strings in a binary, as strings(1) would', () => {
  const buffer = Buffer.concat([
    Buffer.from([0, 1, 2]),
    Buffer.from('hello world'),
    Buffer.from([0]),
    Buffer.from('abc'),
    Buffer.from([0xff]),
    Buffer.from('tail'),
  ]);
  assert.deepEqual(printableRuns(buffer), ['hello world', 'tail']);
  assert.deepEqual(printableRuns(buffer, 3), ['hello world', 'abc', 'tail']);
  assert.deepEqual(printableRuns(Buffer.alloc(0)), []);
});

test('privateNames lists every non-public variable .env.example mentions', () => {
  const names = privateNames(
    'EXPO_PUBLIC_API_URL=x\n# APP_VARIANT=production OTA_ENABLED=false\n# ASC_KEY_ID ASC_KEY_ID\n',
  );
  assert.deepEqual(names, ['APP_VARIANT', 'ASC_KEY_ID', 'OTA_ENABLED']);
  assert.deepEqual(privateNames('nothing here'), []);
});

test('bundleUri keeps the path inside the export, whatever temporary directory held it', () => {
  assert.equal(bundleUri('/tmp/x/_expo/static/js/ios/entry.hbc'), '_expo/static/js/ios/entry.hbc');
  assert.equal(bundleUri('/somewhere/entry.js'), 'entry.js');
});

test('a clean bundle has no findings', () => {
  assert.deepEqual(findingsFor('b', ['https://api.example.com', 'http://localhost'], OPTIONS), []);
});

test('a private variable name in the bundle is high', () => {
  const [finding] = findingsFor('b', ['process.env.APP_VARIANT'], OPTIONS);
  assert.equal(finding.ruleId, 'bundle/private-variable-name');
  assert.equal(finding.severity, 'high');
  // A longer name that merely contains it is a different variable.
  assert.deepEqual(findingsFor('b', ['APP_VARIANTS'], OPTIONS), []);
});

test('every secret shape is critical, and each is matched by a real-looking value', () => {
  // Built from pieces, so the file never holds a string a secret scanner
  // (gitleaks over history, Semgrep's p/secrets) would read as a real key.
  const samples = {
    'private-key': `-----BEGIN RSA ${'PRIVATE'} KEY-----`,
    'stripe-live-key': `sk_live_${'a'.repeat(24)}`,
    'google-api-key': `AIza${'b'.repeat(35)}`,
    'aws-access-key': `${'AKIA'}${'ABCDEFGHIJKLMNOP'}`,
    'github-token': `ghp_${'c'.repeat(36)}`,
    'slack-token': `${'xoxb'}-1234567890-abc`,
    'anthropic-key': `sk-ant-${'d'.repeat(30)}`,
    'openai-key': `sk-proj-${'e'.repeat(40)}`,
  };
  assert.deepEqual(Object.keys(samples).sort(), SECRET_SHAPES.map(([name]) => name).sort());
  for (const [name, sample] of Object.entries(samples)) {
    const findings = findingsFor('b', [sample], OPTIONS).filter(
      (f) => f.ruleId === `bundle/${name}`,
    );
    assert.equal(findings.length, 1, name);
    assert.equal(findings[0].severity, 'critical');
  }
});

test('a cleartext URL is medium unless its host is listed, and is reported once', () => {
  const findings = findingsFor(
    'b',
    ['http://evil.example.com/a', 'http://EVIL.example.com./b'],
    OPTIONS,
  );
  assert.deepEqual(rules(findings), ['MASTG-TEST-0233']);
  assert.equal(findings[0].severity, 'medium');
  assert.match(findings[0].message, /http:\/\/evil\.example\.com /);
});

test('with bundle.hosts empty any https host is fine; once listed, others are low', () => {
  const strings = ['https://api.example.com', 'https://tracker.example.net'];
  assert.deepEqual(findingsFor('b', strings, OPTIONS), []);
  const findings = findingsFor('b', strings, { ...OPTIONS, hosts: ['api.example.com'] });
  assert.deepEqual(rules(findings), ['bundle/unlisted-host']);
  assert.equal(findings[0].severity, 'low');
  assert.match(findings[0].message, /^tracker\.example\.net is not in bundle\.hosts/);
});

test('main reads the bundles and .env.example and prints one SARIF document', () => {
  const dir = mkdtempSync(path.join(tmpdir(), 'bundle-'));
  try {
    const file = path.join(dir, '_expo', 'entry.hbc');
    const files = {
      '.env.example': '# OTA_ENABLED=false\n',
      [file]: Buffer.from('\0uses OTA_ENABLED here\0http://plain.example.com\0'),
    };
    const out = [];
    const code = main([file], {
      log: (l) => out.push(l),
      env: { SECURITY_SETTINGS_FILE: path.join(dir, 'none.json') },
      read: (name, encoding) => (encoding ? String(files[name]) : files[name]),
    });
    assert.equal(code, 0);
    const doc = JSON.parse(out[0]);
    assert.equal(doc.runs[0].tool.driver.name, 'bundle');
    assert.deepEqual(rules(doc.runs[0].results), [
      'bundle/private-variable-name',
      'MASTG-TEST-0233',
    ]);
    assert.equal(
      doc.runs[0].results[0].locations[0].physicalLocation.artifactLocation.uri,
      '_expo/entry.hbc',
    );
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('main with no bundle says how to call it and exits 2', () => {
  const errors = [];
  assert.equal(main([], { error: (l) => errors.push(l) }), 2);
  assert.match(errors[0], /usage: security-bundle.mjs/);
});

test('readOptional is a file, or nothing when there is none, and any other failure throws', () => {
  const missing = () => {
    throw Object.assign(new Error('no'), { code: 'ENOENT' });
  };
  const denied = () => {
    throw Object.assign(new Error('denied'), { code: 'EACCES' });
  };
  assert.equal(readOptional(() => 'A_B=1', '.env.example'), 'A_B=1');
  assert.equal(readOptional(missing, '.env.example'), '');
  assert.throws(() => readOptional(denied, '.env.example'), /denied/);
});

test('runs as a script', () => {
  const dir = mkdtempSync(path.join(tmpdir(), 'bundle-'));
  try {
    const file = path.join(dir, 'entry.js');
    writeFileSync(file, 'nothing to see');
    const run = spawnSync(process.execPath, [path.join(here, 'lib', 'security-bundle.mjs'), file], {
      encoding: 'utf8',
      cwd: here,
      env: process.env,
    });
    assert.equal(run.status, 0, run.stderr);
    assert.deepEqual(JSON.parse(run.stdout).runs[0].results, []);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
