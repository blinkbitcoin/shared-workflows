import assert from 'node:assert/strict';
import { test } from 'node:test';
import importMetaUrl from './expo/jest/import-meta-url.cjs';

// The plugin is run as Babel runs it: called with Babel's API, its
// `MemberExpression` visitor handed a path and the file's state. Babel itself
// is the app's, never this package's, so `types` is a stand-in that builds
// and recognises the same node shapes (`@babel/types`), and `print` reads a
// node back as source.
const types = {
  isMetaProperty: (node) => node.type === 'MetaProperty',
  isIdentifier: (node, { name }) => node.type === 'Identifier' && node.name === name,
  identifier: (name) => ({ type: 'Identifier', name }),
  stringLiteral: (value) => ({ type: 'StringLiteral', value }),
  memberExpression: (object, property, computed = false) => ({ type: 'MemberExpression', object, property, computed }),
  callExpression: (callee, args) => ({ type: 'CallExpression', callee, arguments: args }),
};

/** `meta.property`, as Babel parses `import.meta` or `new.target`. */
const metaProperty = (meta, property) => ({
  type: 'MetaProperty',
  meta: types.identifier(meta),
  property: types.identifier(property),
});

/** The source a node reads back as. */
function print(node) {
  switch (node.type) {
    case 'Identifier':
      return node.name;
    case 'StringLiteral':
      return JSON.stringify(node.value);
    case 'MetaProperty':
      return `${node.meta.name}.${node.property.name}`;
    case 'MemberExpression':
      return node.computed
        ? `${print(node.object)}[${print(node.property)}]`
        : `${print(node.object)}.${print(node.property)}`;
    default:
      return `${print(node.callee)}(${node.arguments.map(print).join(', ')})`;
  }
}

/** The member expression after the plugin has visited it in `filename`, as source. */
function visit(node, filename) {
  const path = {
    node,
    replaceWith(replacement) {
      this.node = replacement;
    },
  };
  importMetaUrl({ types }).visitor.MemberExpression(path, { filename });
  return print(path.node);
}

const importMeta = (property, computed) => types.memberExpression(metaProperty('import', 'meta'), types.identifier(property), computed);
const DEPENDENCY = '/app/node_modules/@mswjs/interceptors/lib/node/source-abc.js';
const OWN_FILE_URL = 'require("node:url").pathToFileURL(__filename).href';

test('the plugin is named for what it does', () => {
  assert.equal(importMetaUrl({ types }).name, 'import-meta-url-in-dependencies');
});

test("in a dependency, import.meta.url becomes the file's own URL", () => {
  assert.equal(visit(importMeta('url'), DEPENDENCY), OWN_FILE_URL);
  // pnpm's store, and a Windows path.
  assert.equal(visit(importMeta('url'), '/app/node_modules/.pnpm/msw@3.0.1/node_modules/msw/lib/a.js'), OWN_FILE_URL);
  assert.equal(visit(importMeta('url'), 'C:\\app\\node_modules\\msw\\lib\\a.js'), OWN_FILE_URL);
});

test("the app's own code keeps babel-preset-expo's rewrite", () => {
  assert.equal(visit(importMeta('url'), '/app/src/api/client.ts'), 'import.meta.url');
  // A directory merely named like it is not a dependency.
  assert.equal(visit(importMeta('url'), '/app/src/node_modules_list.ts'), 'import.meta.url');
});

test('code Babel was handed without a file name is left alone', () => {
  assert.equal(visit(importMeta('url'), undefined), 'import.meta.url');
});

test('every other import.meta property, and every other url, is left alone in a dependency too', () => {
  assert.equal(visit(importMeta('env'), DEPENDENCY), 'import.meta.env');
  assert.equal(visit(importMeta('url', true), DEPENDENCY), 'import.meta[url]');
  assert.equal(visit(types.memberExpression(types.identifier('location'), types.identifier('url')), DEPENDENCY), 'location.url');
  assert.equal(visit(types.memberExpression(metaProperty('new', 'target'), types.identifier('url')), DEPENDENCY), 'new.target.url');
  // Not JavaScript Babel would parse, but the check reads both halves of the meta property.
  assert.equal(visit(types.memberExpression(metaProperty('import', 'other'), types.identifier('url')), DEPENDENCY), 'import.other.url');
});
