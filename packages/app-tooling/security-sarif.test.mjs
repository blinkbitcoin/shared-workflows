import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { fromBom, fromFindings, main, noted, parseLine, skipped } from './lib/security-sarif.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));

test('a skipped run says why, and is not a clean run', () => {
  const doc = skipped('osv-scanner', 'osv-scanner is not installed');
  const [run] = doc.runs;
  assert.equal(doc.version, '2.1.0');
  assert.equal(run.tool.driver.name, 'osv-scanner');
  assert.deepEqual(run.results, []);
  assert.equal(run.invocations[0].executionSuccessful, false);
  assert.match(
    run.invocations[0].toolExecutionNotifications[0].message.text,
    /skipped: osv-scanner is not installed/,
  );
});

test('findings become results with a level and a GitHub severity', () => {
  const doc = fromFindings('semgrep', [
    {
      ruleId: 'rn/cleartext-fetch',
      file: 'src/api.ts',
      line: 12,
      severity: 'high',
      message: 'http:// URL',
    },
    {
      ruleId: 'rn/webview-js',
      file: 'src/web.tsx',
      line: 3,
      severity: 'low',
      message: 'injected JavaScript',
    },
  ]);
  const [run] = doc.runs;
  assert.equal(run.invocations[0].executionSuccessful, true);
  assert.equal(run.results[0].level, 'error');
  assert.equal(run.results[0].properties['security-severity'], '7.0');
  assert.equal(run.results[0].locations[0].physicalLocation.artifactLocation.uri, 'src/api.ts');
  assert.equal(run.results[0].locations[0].physicalLocation.region.startLine, 12);
  assert.equal(run.results[1].level, 'note');
  assert.equal(run.results[1].properties['security-severity'], '1.0');
});

test('a finding with no findings at all is a clean run, not a skipped one', () => {
  const [run] = fromFindings('semgrep', []).runs;
  assert.deepEqual(run.results, []);
  assert.equal(run.invocations[0].executionSuccessful, true);
});

test('an unknown severity is rejected by name', () => {
  assert.throws(
    () =>
      fromFindings('semgrep', [
        { ruleId: 'r', file: 'f', line: 1, severity: 'spicy', message: 'm' },
      ]),
    /spicy/,
  );
});

test('parseLine reads the ok/warn/skip/FAIL line protocol', () => {
  assert.equal(parseLine('ok\tMASTG-TEST-0226\tandroid\tnot debuggable'), null);
  assert.deepEqual(
    parseLine('FAIL\tMASTG-TEST-0226\tandroid/AndroidManifest.xml:4\tdebuggable is true'),
    {
      ruleId: 'MASTG-TEST-0226',
      file: 'android/AndroidManifest.xml',
      line: 4,
      severity: 'high',
      message: 'debuggable is true',
    },
  );
  assert.equal(parseLine('warn\tR\tf:2\tm').severity, 'medium');
  assert.equal(parseLine('skip\tR\tf\tno binary'), null);
  assert.equal(parseLine(''), null);
});

test('a line with no line number lands on line 1', () => {
  assert.equal(parseLine('FAIL\tR\tsome/file\tm').line, 1);
});

test('an unknown verb names the line', () => {
  assert.throws(() => parseLine('maybe\tR\tf\tm'), /unknown verb "maybe"/);
});

test('the CLI writes a skipped document', () => {
  const out = [];
  assert.equal(
    main(['skip', 'osv-scanner', 'not', 'installed'], { log: (l) => out.push(l), error: () => {} }),
    0,
  );
  assert.equal(JSON.parse(out[0]).runs[0].invocations[0].executionSuccessful, false);
});

test('the CLI turns NDJSON lines into a document', () => {
  const dir = mkdtempSync(path.join(tmpdir(), 'sarif-'));
  try {
    const file = path.join(dir, 'lines');
    writeFileSync(file, 'FAIL\tR\tf.ts:9\tboom\nok\tR\tf.ts\tfine\n');
    const out = [];
    assert.equal(
      main(['lines', 'checks'], { log: (l) => out.push(l), error: () => {}, stdin: file }),
      0,
    );
    assert.equal(JSON.parse(out[0]).runs[0].results.length, 1);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('a bad invocation exits 2 and says how to call it', () => {
  const out = [];
  assert.equal(main(['nonsense'], { log: () => {}, error: (l) => out.push(l) }), 2);
  assert.match(out[0], /usage: security-sarif.mjs/);
});

test('runs as a script', () => {
  const run = spawnSync(process.execPath, [path.join(here, 'lib', 'security-sarif.mjs'), 'skip', 't', 'r'], {
    encoding: 'utf8',
    env: process.env,
  });
  assert.equal(run.status, 0);
  assert.match(run.stdout, /skipped: r/);
});

// ---------- severity verbs, notes and the bill of materials ----------

test('a line may name its severity outright', () => {
  for (const severity of ['critical', 'high', 'medium', 'low']) {
    assert.equal(parseLine(`${severity}\tMASTG-TEST-0226\tapp.apk\tdebuggable`).severity, severity);
  }
});

test('a verb that only exists on Object.prototype is still an unknown verb', () => {
  assert.throws(() => parseLine('constructor\tR\tf\tm'), /unknown verb "constructor"/);
  assert.throws(() => parseLine('toString\tR\tf\tm'), /unknown verb "toString"/);
});

test('a noted run is clean and still carries its note', () => {
  const doc = noted('sbom', '12 components');
  const [invocation] = doc.runs[0].invocations;
  assert.equal(invocation.executionSuccessful, true);
  assert.equal(invocation.toolExecutionNotifications[0].message.text, '12 components');
  assert.deepEqual(doc.runs[0].results, []);
});

test('a bill of materials becomes a clean run that counts its components', () => {
  const doc = fromBom('sbom', { bomFormat: 'CycloneDX', components: [{}, {}] });
  assert.match(
    doc.runs[0].invocations[0].toolExecutionNotifications[0].message.text,
    /^2 components/,
  );
});

test('a bill that is not CycloneDX, or lists nothing, is a broken run', () => {
  assert.throws(() => fromBom('sbom', { bomFormat: 'SPDX' }), /not a CycloneDX document/);
  assert.throws(() => fromBom('sbom', null), /not a CycloneDX document/);
  assert.throws(() => fromBom('sbom', { bomFormat: 'CycloneDX', components: [] }), /no components/);
  assert.throws(() => fromBom('sbom', { bomFormat: 'CycloneDX' }), /no components/);
});

test('the CLI reads a bill from a file and fails on a bad one', () => {
  const dir = mkdtempSync(path.join(tmpdir(), 'sarif-'));
  try {
    const good = path.join(dir, 'good.json');
    const bad = path.join(dir, 'bad.json');
    writeFileSync(good, JSON.stringify({ bomFormat: 'CycloneDX', components: [{}] }));
    writeFileSync(bad, '{');
    const out = [];
    const err = [];
    const io = { log: (l) => out.push(l), error: (l) => err.push(l) };
    assert.equal(main(['bom', 'sbom', good], io), 0);
    assert.match(out[0], /1 components/);
    assert.equal(main(['bom', 'sbom', bad], io), 1);
    assert.match(err[0], /bad\.json: /);
    assert.equal(main(['bom', 'sbom'], io), 2);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
