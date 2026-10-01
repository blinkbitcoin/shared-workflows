// Every app suite, run through test-app against its fixture apps
// (fixtures/apps/<suite>/). A suite is a test, so no coverage number says it
// works; what does is that it passes on an app in the template's shape and
// fails, saying why, on an app broken in each way it guards against. A suite
// with no fixture it should fail on is reported as unable to fail.
//
// A fixture is `base/`, with one `cases/<case>/` laid over it, and `modules/`
// as its node_modules unless the case's case.json sets `"modules": false`.
// case.json says whether the suite passes and lists patterns its output must
// match; its `removes` lists paths of `base/` the case does not have.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { cpSync, existsSync, mkdtempSync, readdirSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { SUITES } from './suites/index.mjs';

const BIN = fileURLToPath(new URL('./bin/test-app.mjs', import.meta.url));
const FIXTURES = fileURLToPath(new URL('./fixtures/apps/', import.meta.url));

const casesOf = (suite) => {
  const dir = path.join(FIXTURES, suite, 'cases');
  return existsSync(dir) ? readdirSync(dir).sort() : [];
};

/** The fixture app for one case, in a temporary directory. */
const fixtureApp = (t, suite, name, spec) => {
  const app = mkdtempSync(path.join(tmpdir(), `app-suite-${suite}-`));
  t.after(() => rmSync(app, { recursive: true, force: true }));
  cpSync(path.join(FIXTURES, suite, 'base'), app, { recursive: true });
  cpSync(path.join(FIXTURES, suite, 'cases', name), app, { recursive: true });
  rmSync(path.join(app, 'case.json'));
  for (const removed of spec.removes ?? []) rmSync(path.join(app, removed), { recursive: true });
  const modules = path.join(FIXTURES, suite, 'modules');
  if (spec.modules !== false && existsSync(modules)) cpSync(modules, path.join(app, 'node_modules'), { recursive: true });
  return app;
};

test('every suite has fixture apps it passes and fixture apps it fails on', () => {
  for (const suite of Object.keys(SUITES)) {
    const specs = casesOf(suite).map((name) => JSON.parse(readFileSync(path.join(FIXTURES, suite, 'cases', name, 'case.json'), 'utf8')));
    assert.ok(specs.some((spec) => spec.passes === true), `${suite} has no fixture it passes`);
    assert.ok(specs.some((spec) => spec.passes === false), `${suite} has no fixture it fails on, so nothing shows it can fail`);
    for (const spec of specs) assert.ok(Array.isArray(spec.output) && spec.output.length > 0, `${suite}: a case says nothing about the output`);
  }
});

for (const suite of Object.keys(SUITES)) {
  for (const name of casesOf(suite)) {
    test(`${suite}: ${name}`, (t) => {
      const spec = JSON.parse(readFileSync(path.join(FIXTURES, suite, 'cases', name, 'case.json'), 'utf8'));
      const app = fixtureApp(t, suite, name, spec);
      const { NODE_TEST_CONTEXT: _parent, ...env } = process.env;
      const result = spawnSync(process.execPath, [BIN, '--root', app, '--suite', suite], { encoding: 'utf8', env });
      const output = `${result.stdout}${result.stderr}`;
      assert.equal(result.status === 0, spec.passes, `expected the suite to ${spec.passes ? 'pass' : 'fail'}:\n${output}`);
      assert.match(output, new RegExp(`^run ${suite}$`, 'm'));
      for (const pattern of spec.output) assert.match(output, new RegExp(pattern), output);
    });
  }
}
