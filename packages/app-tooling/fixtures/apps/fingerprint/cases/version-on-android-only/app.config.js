// A version on one platform only: the other platform's hash must stay put, and
// the failure must name the one that moved.
module.exports = {
  name: 'fixture',
  slug: 'fixture',
  version: process.env.APP_VERSION || '0.0.0',
  ios: { bundleIdentifier: 'com.example.fixture', buildNumber: process.env.APP_BUILD_NUMBER || '1' },
  android: {
    package: 'com.example.fixture',
    versionCode: Number(process.env.APP_BUILD_NUMBER || 1),
    versionName: process.env.APP_VERSION || '0.0.0',
  },
};
