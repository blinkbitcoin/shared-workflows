// The Playwright configuration for an Expo app's web suite: the exported site
// served the way GitHub Pages serves it, and the mock API it talks to. The app
// wraps the result in its own `defineConfig` from @playwright/test.
//
// The ports come from the environment. The app's port helper derives them from
// one base, and the shell that runs the suite exports them (the template's
// `make test-e2e-web` and `scripts/e2e/web.sh`); this reads what was exported
// rather than importing that helper, which a `.ts` configuration Playwright
// loads through `require()` cannot do in a package without `"type": "module"`.

function required(name, value) {
  if (!value) {
    throw new Error(
      `${name} is not set. Run the web suite through 'make test-e2e-web' or ` +
        `scripts/e2e/web.sh, which export the ports from scripts/ports.mjs.`,
    );
  }
  return value;
}

/**
 * @param {object} [options]
 * @param {Record<string, string | undefined>} [options.env] where the ports and base path are read from
 * @param {string} [options.testDir]
 * @param {string} [options.mockApiCommand] starts the mock API at EXPO_PUBLIC_API_URL
 * @param {string} [options.previewCommand] serves the export at WEB_PREVIEW_PORT
 */
export function createPlaywrightConfig({
  env = process.env,
  testDir = 'e2e/web',
  mockApiCommand = 'pnpm mock-api',
  previewCommand = 'node scripts/e2e/serve-dist.mjs',
} = {}) {
  const webPreviewPort = required('WEB_PREVIEW_PORT', env.WEB_PREVIEW_PORT);
  // A deploy export is built for `/<repository>/` (EXPO_PUBLIC_BASE_URL, set by
  // `build-web.yml` on a deploy and handed to this suite too); a pull request's
  // export and a local one are built for `/`. The preview server serves `dist`
  // under the same path, so the suite tests the export as it will be served.
  const basePath = (env.EXPO_PUBLIC_BASE_URL ?? '').trim().replace(/\/+$/, '');
  // Trailing slash on purpose: Playwright joins a spec's path onto `baseURL`
  // with URL resolution, where a leading `/` discards the base path. Specs
  // therefore navigate with `./` and `./details/42`.
  const previewUrl = `http://localhost:${webPreviewPort}${basePath}/`;
  // The port helper builds this one itself, so read it rather than rebuild the
  // path here and have two places that know about /graphql.
  const mockApiUrl = required('EXPO_PUBLIC_API_URL', env.EXPO_PUBLIC_API_URL);

  return {
    testDir,
    timeout: 30_000,
    use: { baseURL: previewUrl },
    webServer: [
      {
        command: mockApiCommand,
        url: mockApiUrl,
        reuseExistingServer: true,
        timeout: 30_000,
        stdout: 'ignore',
      },
      {
        // Not `expo serve`: it serves at `/` only, and a deploy export's paths
        // all carry the base path. The preview server serves the export the
        // way GitHub Pages does - under the base path, `/settings` from
        // `settings.html`, and `404.html` (with a 404) for a path with no
        // file, which is how a deep link into a dynamic route boots the router.
        command: previewCommand,
        url: previewUrl,
        reuseExistingServer: false,
        timeout: 60_000,
      },
    ],
  };
}
