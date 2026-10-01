// The template's shape: the version inputs reach only the fields
// ExpoConfigVersions skips.
module.exports = {
  name: 'fixture',
  slug: 'fixture',
  version: process.env.APP_VERSION || '0.0.0',
  ios: { bundleIdentifier: 'com.example.fixture', buildNumber: process.env.APP_BUILD_NUMBER || '1' },
  android: { package: 'com.example.fixture', versionCode: Number(process.env.APP_BUILD_NUMBER || 1) },
};
