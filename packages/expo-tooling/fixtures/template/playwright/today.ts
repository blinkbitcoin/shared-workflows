// WEB ONLY
// `pnpm test:e2e:web` exports the site first (`expo export --platform web
// --dev`); the `--dev` flag makes Expo read `.env.development`, so the bundle
// talks to the mock API that the first web server below starts. Both ports come
// from `scripts/ports.mjs`, so `APP_PORT_BASE=8090 make test-e2e-web` moves the whole
// suite out of the way of another worktree.
import { defineConfig } from '@playwright/test';

// The ports still come from `scripts/ports.mjs` — the shell evaluates it and
// exports them (`scripts/e2e/web.sh`, and the `PORTS` macro behind
// `make test-e2e-web`), and this file reads what it exported.
//
// It does not import the module, and cannot: Playwright loads a `.ts` config
// through `require()`, this package.json has no `"type": "module"`, and
// requiring an ES module dies with "Cannot use 'import.meta' outside a
// module". That is what had the web suite red on every branch.
// Static `process.env.NAME` access, never `process.env[name]`: the repo's
// eslint config bans the dynamic form so Expo can inline EXPO_PUBLIC_* at
// build time.
function required(name: string, value: string | undefined): string {
  if (!value) {
    throw new Error(
      `${name} is not set. Run the web suite through 'make test-e2e-web' or ` +
        `scripts/e2e/web.sh, which export the ports from scripts/ports.mjs.`,
    );
  }
  return value;
}

const webPreviewPort = required('WEB_PREVIEW_PORT', process.env.WEB_PREVIEW_PORT);
// A deploy export is built for `/<repo>/` (EXPO_PUBLIC_BASE_URL, set by the
// `build-web` workflow on a deploy and handed to this suite too); a PR export and a
// local one are built for `/`. The preview server serves `dist` under the same
// path, so the suite tests the export as it will be served.
const basePath = (process.env.EXPO_PUBLIC_BASE_URL ?? '').trim().replace(/\/+$/, '');
// Trailing slash on purpose: Playwright joins a spec's path onto `baseURL` with
// URL resolution, where a leading `/` discards the base path. Specs therefore
// navigate with `./` and `./details/42`, which stay under the base path.
const previewUrl = `http://localhost:${webPreviewPort}${basePath}/`;
// ports.mjs builds this one itself (mockApiUrl), so read it rather than
// rebuild the path here and have two places that know about /graphql.
const mockApiUrl = required('EXPO_PUBLIC_API_URL', process.env.EXPO_PUBLIC_API_URL);

export default defineConfig({
  testDir: 'e2e/web',
  timeout: 30_000,
  use: { baseURL: previewUrl },
  webServer: [
    {
      command: 'pnpm mock-api',
      url: mockApiUrl,
      reuseExistingServer: true,
      timeout: 30_000,
      stdout: 'ignore',
    },
    {
      // Not `expo serve`: it serves at `/` only, and a deploy export's paths
      // all carry the base path. scripts/e2e/serve-dist.mjs serves the export
      // the way GitHub Pages does - under the base path, `/settings` from
      // `settings.html`, and `404.html` (with a 404) for a path with no file,
      // which is how a deep link into a dynamic route boots the router.
      command: 'node scripts/e2e/serve-dist.mjs',
      url: previewUrl,
      reuseExistingServer: false,
      timeout: 60_000,
    },
  ],
});
