// Expo's default Metro config plus one resolver fix.
const path = require('node:path');
const { getDefaultConfig } = require('expo/metro-config');

const config = getDefaultConfig(__dirname);

// Claude Code's git worktrees under `.claude/worktrees/` are whole checkouts of
// this repository, node_modules included, and Metro crawls everything under the
// project root. Matched both project-relative (Expo's crawler prunes the
// directory, like its own `ios/Pods` entry) and absolute, anchored to this
// root: a worktree's own root is itself under `.claude/worktrees/`, so an
// unanchored pattern would block the whole app there.
const escapeRegExp = (text) => text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
config.resolver.blockList = [
  ...[].concat(config.resolver.blockList ?? []),
  new RegExp(`^(?:${escapeRegExp(__dirname + path.sep)})?\\.claude[\\\\/]worktrees(?:[\\\\/]|$)`),
];

// init:web-start
// expo-sqlite's web implementation (wa-sqlite) imports a .wasm file, which is
// not a Metro asset extension by default.
config.resolver.assetExts.push('wasm');

// `expo export --platform web` renders the routes in a Node bundle first
// (web.output: 'static'). Under the `node` + `import` conditions, `tslib`
// resolves to `tslib/modules/index.js`, which default-imports the UMD
// `tslib.js`; Metro's interop leaves that default `undefined`, so rxjs (via
// @apollo/client) crashes with "Cannot destructure property '__extends'".
// Pinning the web resolution to tslib's ESM build exports the helpers directly.
// Native bundles resolve tslib normally and are untouched.
const defaultResolveRequest = config.resolver.resolveRequest;
config.resolver.resolveRequest = (context, moduleName, platform) => {
  const resolve = defaultResolveRequest ?? context.resolveRequest;
  if (platform === 'web' && moduleName === 'tslib') {
    return resolve(context, 'tslib/tslib.es6.mjs', platform);
  }
  return resolve(context, moduleName, platform);
};
// init:web-end

module.exports = config;
