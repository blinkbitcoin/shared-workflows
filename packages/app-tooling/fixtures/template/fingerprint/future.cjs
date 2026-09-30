// Fingerprint (runtimeVersion policy "fingerprint") inputs: the shared source
// skips and ignore paths. Replaces .fingerprintignore as well. Guarded by
// scripts/release/fingerprint.test.mjs.
const { createFingerprintConfig } = require('@blinkbitcoin/app-tooling/expo/fingerprint');

module.exports = createFingerprintConfig();
