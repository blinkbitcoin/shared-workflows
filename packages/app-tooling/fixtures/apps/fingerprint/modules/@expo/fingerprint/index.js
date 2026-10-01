// A stand-in for @expo/fingerprint: see the README beside fixtures/apps/fingerprint/.
const crypto = require('node:crypto');
const path = require('node:path');

function loadOptions(root) {
  try {
    return require(path.join(root, 'fingerprint.config.js'));
  } catch {
    return {};
  }
}

exports.createFingerprintAsync = async (root, { platforms }) => {
  const options = loadOptions(root);
  const config = JSON.parse(JSON.stringify(require(path.join(root, 'app.config.js'))));
  if ((options.sourceSkips ?? []).includes('ExpoConfigVersions')) {
    delete config.version;
    delete config.ios.buildNumber;
    delete config.android.versionCode;
  }
  const [platform] = platforms;
  delete config[platform === 'ios' ? 'android' : 'ios'];
  return { hash: crypto.createHash('sha1').update(JSON.stringify(config)).digest('hex') };
};
