import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import path from 'node:path';
import { test } from 'node:test';
import { stubModules } from './fixtures/stubs/register.mjs';

// expo/metro-config is the app's; here it is a stand-in whose getDefaultConfig
// returns a fresh configuration per call, shaped by two globals a case sets.
stubModules({ 'expo/metro-config': 'expo-metro-config.cjs' });

const { webResolveRequest, withSharedMetroConfig, worktreeBlock } = await import('./expo/metro.mjs');

const require = createRequire(import.meta.url);
const TODAY = require.resolve('./fixtures/template/metro/today.cjs');
const FUTURE = require.resolve('./fixtures/template/metro/future.cjs');

// Both files sit in the same directory, so `__dirname` - the project root -
// is the same for the two, as it is for the template before and after.
function load(file, { blockList, resolveRequest } = {}) {
  globalThis.metroDefaultBlockList = blockList;
  globalThis.metroDefaultResolveRequest = resolveRequest;
  delete require.cache[file];
  return require(file);
}

// What a resolver does is its behaviour, so the two are compared on the calls
// that matter: tslib on web, tslib on a native platform, anything else on web.
function resolutions(config) {
  const seen = [];
  const context = { resolveRequest: (_context, name, platform) => seen.push(['context', name, platform]) };
  for (const [name, platform] of [
    ['tslib', 'web'],
    ['tslib', 'ios'],
    ['react', 'web'],
  ]) {
    config.resolver.resolveRequest(context, name, platform);
  }
  return seen;
}

for (const [label, defaults] of [
  ['with no default block list or resolver', {}],
  ['with a default block list and resolver of its own', {
    blockList: [/\.expo\/types/],
    resolveRequest: (_context, name, platform) => ['default', name, platform],
  }],
]) {
  test(`the template's future metro.config.js produces today's configuration, ${label}`, () => {
    const today = load(TODAY, defaults);
    const future = load(FUTURE, defaults);
    assert.deepStrictEqual(future.resolver.blockList, today.resolver.blockList);
    assert.deepStrictEqual(future.resolver.assetExts, today.resolver.assetExts);
    assert.deepStrictEqual(future.projectRoot, today.projectRoot);
    if (defaults.resolveRequest) {
      for (const [name, platform] of [['tslib', 'web'], ['tslib', 'ios'], ['react', 'web']]) {
        assert.deepStrictEqual(
          future.resolver.resolveRequest({}, name, platform),
          today.resolver.resolveRequest({}, name, platform),
        );
      }
    } else {
      assert.deepStrictEqual(resolutions(future), resolutions(today));
    }
  });
}

test('web resolves tslib to its ES module build, and leaves everything else alone', () => {
  const resolve = webResolveRequest((_context, name, platform) => `${platform}:${name}`);
  assert.equal(resolve({}, 'tslib', 'web'), 'web:tslib/tslib.es6.mjs');
  assert.equal(resolve({}, 'tslib', 'android'), 'android:tslib');
  assert.equal(resolve({}, 'rxjs', 'web'), 'web:rxjs');
});

test('without a default resolver it falls back to the one Metro passes in the context', () => {
  const resolve = webResolveRequest(undefined);
  const context = { resolveRequest: (_context, name) => `context:${name}` };
  assert.equal(resolve(context, 'tslib', 'web'), 'context:tslib/tslib.es6.mjs');
});

test('the worktree block matches relative and anchored paths, never a worktree of its own root', () => {
  const root = path.join(path.sep, 'repo');
  const block = worktreeBlock(root);
  assert.ok(block.test('.claude/worktrees/topic/src/index.ts'), 'project-relative');
  assert.ok(block.test(path.join(root, '.claude', 'worktrees')), 'the directory itself');
  assert.ok(block.test(path.join(root, '.claude', 'worktrees', 'topic', 'index.ts')), 'absolute under this root');
  assert.ok(!block.test(path.join(root, 'src', '.claude', 'worktrees', 'x')), 'not anchored elsewhere');
  const worktree = path.join(root, '.claude', 'worktrees', 'topic');
  assert.ok(!worktreeBlock(worktree).test(path.join(worktree, 'src', 'index.ts')), "a worktree's own files");
  assert.ok(worktreeBlock('/a.b').test('/a.b/.claude/worktrees'), 'the root is escaped');
  assert.ok(!worktreeBlock('/a.b').test('/axb/.claude/worktrees'), 'a dot in the root is literal');
});

test('a single default block list pattern is kept alongside the worktree block', () => {
  const config = { projectRoot: '/repo', resolver: { blockList: /existing/, assetExts: [] } };
  withSharedMetroConfig(config);
  assert.deepEqual(config.resolver.blockList, [/existing/, worktreeBlock('/repo')]);
});

test('an app with no web target gets the worktree block and nothing else', () => {
  const resolveRequest = () => 'default';
  const config = { projectRoot: '/repo', resolver: { assetExts: ['png'], resolveRequest } };
  assert.equal(withSharedMetroConfig(config, { web: false }), config);
  assert.deepEqual(config.resolver.blockList, [worktreeBlock('/repo')]);
  assert.deepEqual(config.resolver.assetExts, ['png']);
  assert.equal(config.resolver.resolveRequest, resolveRequest);
});

test('the web fixes add the wasm asset extension and wrap the resolver', () => {
  const config = withSharedMetroConfig({ projectRoot: '/repo', resolver: { assetExts: ['png'] } });
  assert.deepEqual(config.resolver.assetExts, ['png', 'wasm']);
  assert.equal(typeof config.resolver.resolveRequest, 'function');
});
