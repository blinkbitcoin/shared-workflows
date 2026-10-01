// A version copied into a field the fingerprint reads.
module.exports = {
  name: 'fixture',
  slug: 'fixture',
  version: process.env.APP_VERSION || '0.0.0',
  extra: { version: process.env.APP_VERSION || '0.0.0' },
  ios: { bundleIdentifier: 'com.example.fixture', buildNumber: process.env.APP_BUILD_NUMBER || '1' },
  android: { package: 'com.example.fixture', versionCode: Number(process.env.APP_BUILD_NUMBER || 1) },
};
