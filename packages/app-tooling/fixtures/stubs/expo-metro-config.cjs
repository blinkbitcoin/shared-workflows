// expo/metro-config: getDefaultConfig returns a fresh configuration per call,
// with a block list, asset extensions and, when a test sets
// `globalThis.metroDefaultResolveRequest`, a resolveRequest of its own.
module.exports = {
  getDefaultConfig: (projectRoot) => ({
    projectRoot,
    resolver: {
      blockList: globalThis.metroDefaultBlockList,
      assetExts: ['png', 'ttf'],
      resolveRequest: globalThis.metroDefaultResolveRequest,
    },
  }),
};
