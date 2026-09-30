// Expo's default Metro config, plus the shared worktree block and web fixes.
const { getDefaultConfig } = require('expo/metro-config');
const { withSharedMetroConfig } = require('@blinkbitcoin/expo-tooling/metro');

module.exports = withSharedMetroConfig(getDefaultConfig(__dirname));
