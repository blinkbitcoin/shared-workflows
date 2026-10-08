// A Babel plugin createJestConfig adds to the app project's script transform:
// in a file under node_modules, `import.meta.url` becomes that file's own URL,
// `require("node:url").pathToFileURL(__filename).href`.
//
// babel-preset-expo rewrites `import.meta` to `globalThis.__ExpoImportMetaRegistry`,
// whose `url` is the bundle's URL: right in a Metro bundle, empty under Jest. A
// dependency that finds a file next to itself, as `@mswjs/interceptors` 0.45
// (msw 3) does with `new URL("./llhttp/llhttp.wasm", import.meta.url)`, then
// throws "Invalid URL" as it loads. Plugins run before presets in the same
// traversal, so this rewrite happens first. The app's own code keeps the
// preset's rewrite, and every other `import.meta` property is left alone.
'use strict';

const DEPENDENCY = /[\\/]node_modules[\\/]/;

/** Whether `node` is `import.meta.url`, written with a dot. */
function isImportMetaUrl(types, node) {
  return (
    types.isMetaProperty(node.object) &&
    node.object.meta.name === 'import' &&
    node.object.property.name === 'meta' &&
    types.isIdentifier(node.property, { name: 'url' }) &&
    !node.computed
  );
}

/** `require("node:url").pathToFileURL(__filename).href`, as an expression node. */
function ownFileUrl(types) {
  const nodeUrl = types.callExpression(types.identifier('require'), [types.stringLiteral('node:url')]);
  const pathToFileURL = types.memberExpression(nodeUrl, types.identifier('pathToFileURL'));
  const fileUrl = types.callExpression(pathToFileURL, [types.identifier('__filename')]);
  return types.memberExpression(fileUrl, types.identifier('href'));
}

module.exports = function importMetaUrl({ types }) {
  return {
    name: 'import-meta-url-in-dependencies',
    visitor: {
      MemberExpression(path, state) {
        if (!DEPENDENCY.test(state.filename ?? '')) return;
        if (isImportMetaUrl(types, path.node)) path.replaceWith(ownFileUrl(types));
      },
    },
  };
};
