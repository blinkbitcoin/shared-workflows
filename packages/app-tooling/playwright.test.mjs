import assert from 'node:assert/strict';
import { test } from 'node:test';
import { stubModules } from './fixtures/stubs/register.mjs';

// @playwright/test is the app's; here its defineConfig returns what it is given.
stubModules({ '@playwright/test': 'playwright-test.mjs' });

const { createPlaywrightConfig } = await import('./expo/playwright.mjs');

// The template's file reads the environment when it is evaluated, so each case
// sets the three variables it reads and then loads both files fresh (a
// distinct query string is a distinct module instance).
const NAMES = ['WEB_PREVIEW_PORT', 'EXPO_PUBLIC_API_URL', 'EXPO_PUBLIC_BASE_URL'];
async function withEnv(env, run) {
  const saved = Object.fromEntries(NAMES.map((name) => [name, process.env[name]]));
  for (const name of NAMES) {
    if (env[name] === undefined) delete process.env[name];
    else process.env[name] = env[name];
  }
  try {
    return await run();
  } finally {
    for (const name of NAMES) {
      if (saved[name] === undefined) delete process.env[name];
      else process.env[name] = saved[name];
    }
  }
}

let fresh = 0;
const load = (env) =>
  withEnv(env, async () => {
    fresh += 1;
    const settle = (file) =>
      import(`./fixtures/template/playwright/${file}?${fresh}`).then(
        (module) => ({ config: module.default }),
        (error) => ({ error: error.message }),
      );
    return { today: await settle('today.ts'), future: await settle('future.ts') };
  });

const PORTS = { WEB_PREVIEW_PORT: '8083', EXPO_PUBLIC_API_URL: 'http://localhost:8082/graphql' };

for (const [label, env] of [
  ['a local run, served at /', PORTS],
  ['a deploy export, served under its base path', { ...PORTS, EXPO_PUBLIC_BASE_URL: ' /mobile-app// ' }],
  ['no preview port', { EXPO_PUBLIC_API_URL: PORTS.EXPO_PUBLIC_API_URL }],
  ['no mock API address', { WEB_PREVIEW_PORT: PORTS.WEB_PREVIEW_PORT }],
]) {
  test(`the template's future playwright.config.ts behaves as today's for ${label}`, async () => {
    const { today, future } = await load(env);
    assert.deepStrictEqual(future, today);
  });
}

test('the base path is trimmed and keeps the trailing slash specs navigate from', () => {
  const config = createPlaywrightConfig({ env: { ...PORTS, EXPO_PUBLIC_BASE_URL: '/app/' } });
  assert.equal(config.use.baseURL, 'http://localhost:8083/app/');
  assert.equal(config.webServer[1].url, 'http://localhost:8083/app/');
  assert.equal(config.webServer[0].url, PORTS.EXPO_PUBLIC_API_URL);
});

test('a missing port names the variable and how to set it', () => {
  assert.throws(() => createPlaywrightConfig({ env: {} }), /WEB_PREVIEW_PORT is not set\. Run the web suite through 'make test-e2e-web'/);
  assert.throws(() => createPlaywrightConfig({ env: { WEB_PREVIEW_PORT: '1' } }), /EXPO_PUBLIC_API_URL is not set/);
});

test('the preview server is this package\'s serve-dist unless an app names its own', () => {
  assert.equal(createPlaywrightConfig({ env: PORTS }).webServer[1].command, 'pnpm exec serve-dist');
});

test('an app can move the suite and name its own servers', () => {
  const config = createPlaywrightConfig({
    env: PORTS,
    testDir: 'web-tests',
    mockApiCommand: 'pnpm api',
    previewCommand: 'pnpm preview',
  });
  assert.equal(config.testDir, 'web-tests');
  assert.deepEqual(config.webServer.map((server) => server.command), ['pnpm api', 'pnpm preview']);
});

test('with no options it reads process.env', async () => {
  await withEnv(PORTS, () => {
    assert.equal(createPlaywrightConfig().use.baseURL, 'http://localhost:8083/');
  });
});
