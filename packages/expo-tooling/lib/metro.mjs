// What every Expo app of this family adds to Expo's default Metro
// configuration: the worktree block, and the two fixes a web export needs. It
// takes the configuration `getDefaultConfig` returned and changes it in place,
// so the app keeps calling Expo itself and this package needs no Expo import.
import path from 'node:path';

const escapeRegExp = (text) => text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

/**
 * Claude Code's git worktrees under `.claude/worktrees/` are whole checkouts
 * of the repository, node_modules included, and Metro crawls everything under
 * the project root. Matched both project-relative (Expo's crawler prunes the
 * directory, like its own `ios/Pods` entry) and absolute, anchored to the
 * project root: a worktree's own root is itself under `.claude/worktrees/`,
 * so an unanchored pattern would block the whole app there.
 */
export const worktreeBlock = (projectRoot) =>
  new RegExp(`^(?:${escapeRegExp(projectRoot + path.sep)})?\\.claude[\\\\/]worktrees(?:[\\\\/]|$)`);

/**
 * `expo export --platform web` renders the routes in a Node bundle first
 * (web.output: 'static'). Under the `node` + `import` conditions, `tslib`
 * resolves to `tslib/modules/index.js`, which default-imports the UMD
 * `tslib.js`; Metro's interop leaves that default `undefined`, so rxjs (via
 * @apollo/client) crashes with "Cannot destructure property '__extends'".
 * Pinning the web resolution to tslib's ESM build exports the helpers
 * directly. Native bundles resolve tslib normally and are untouched.
 */
export const webResolveRequest = (defaultResolveRequest) => (context, moduleName, platform) => {
  const resolve = defaultResolveRequest ?? context.resolveRequest;
  if (platform === 'web' && moduleName === 'tslib') {
    return resolve(context, 'tslib/tslib.es6.mjs', platform);
  }
  return resolve(context, moduleName, platform);
};

/**
 * @param {object} config what `getDefaultConfig(__dirname)` from `expo/metro-config` returned
 * @param {object} [options]
 * @param {boolean} [options.web] false for an app with no web target: leaves the web fixes out
 * @returns the same configuration, changed
 */
export function withSharedMetroConfig(config, { web = true } = {}) {
  config.resolver.blockList = [
    ...[].concat(config.resolver.blockList ?? []),
    worktreeBlock(config.projectRoot),
  ];
  if (web) {
    // expo-sqlite's web implementation (wa-sqlite) imports a .wasm file, which
    // is not a Metro asset extension by default.
    config.resolver.assetExts.push('wasm');
    config.resolver.resolveRequest = webResolveRequest(config.resolver.resolveRequest);
  }
  return config;
}
