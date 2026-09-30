#!/usr/bin/env node
// OWASP MASTG checks over the built release binaries - what actually ships,
// rather than the configuration that was meant to produce it. binaries.sh
// extracts the evidence with the platform tools and hands it over as files:
//
//   --android-manifest F   `aapt2 dump xmltree --file AndroidManifest.xml <apk>`
//   --android-nsc F        the same dump of the network security config, if any
//   --android-signer F     `apksigner verify --print-certs -v <apk>`
//   --android-file NAME    the APK's name, for the finding's location
//   --ios-info F           the .app's Info.plist as JSON
//   --ios-entitlements F   the embedded provisioning profile's Entitlements as JSON
//   --ios-file NAME        the IPA's name, for the finding's location
//   --note TEXT            a check that could not run, carried into the run
//
// Every rule is named by its MASTG test identifier (mas.owasp.org), so a
// finding links straight to the test that explains it. Allowlists live in
// security-settings.json under jobs.binaries.
import { readFileSync } from 'node:fs';
import { fromFindings } from './security-sarif.mjs';
import { load } from './security-settings.mjs';
import { isProgram } from './is-program.mjs';

// Android's "dangerous" runtime permissions plus the special-access ones a
// user grants in Settings. Both are what MASTG-TEST-0254 means by a permission
// the app should have to justify.
export const DANGEROUS_PERMISSIONS = new Set(
  [
    'ACCEPT_HANDOVER',
    'ACCESS_BACKGROUND_LOCATION',
    'ACCESS_COARSE_LOCATION',
    'ACCESS_FINE_LOCATION',
    'ACCESS_MEDIA_LOCATION',
    'ACTIVITY_RECOGNITION',
    'ADD_VOICEMAIL',
    'ANSWER_PHONE_CALLS',
    'BLUETOOTH_ADVERTISE',
    'BLUETOOTH_CONNECT',
    'BLUETOOTH_SCAN',
    'BODY_SENSORS',
    'BODY_SENSORS_BACKGROUND',
    'CALL_PHONE',
    'CAMERA',
    'GET_ACCOUNTS',
    'MANAGE_EXTERNAL_STORAGE',
    'NEARBY_WIFI_DEVICES',
    'PACKAGE_USAGE_STATS',
    'POST_NOTIFICATIONS',
    'PROCESS_OUTGOING_CALLS',
    'QUERY_ALL_PACKAGES',
    'READ_CALENDAR',
    'READ_CALL_LOG',
    'READ_CONTACTS',
    'READ_EXTERNAL_STORAGE',
    'READ_MEDIA_AUDIO',
    'READ_MEDIA_IMAGES',
    'READ_MEDIA_VIDEO',
    'READ_MEDIA_VISUAL_USER_SELECTED',
    'READ_PHONE_NUMBERS',
    'READ_PHONE_STATE',
    'READ_SMS',
    'RECEIVE_MMS',
    'RECEIVE_SMS',
    'RECEIVE_WAP_PUSH',
    'RECORD_AUDIO',
    'REQUEST_INSTALL_PACKAGES',
    'SEND_SMS',
    'SYSTEM_ALERT_WINDOW',
    'USE_SIP',
    'UWB_RANGING',
    'WRITE_CALENDAR',
    'WRITE_CALL_LOG',
    'WRITE_CONTACTS',
    'WRITE_EXTERNAL_STORAGE',
    'WRITE_SETTINGS',
  ].map((name) => `android.permission.${name}`),
);

const ELEMENT = /^(\s*)E: (\S+)/;
const TEXT = /^\s*T: '(.*)'$/;
const ATTRIBUTE = /^\s*A: (?:[^\s=]*:)?([A-Za-z_][\w]*)(?:\(0x[0-9a-f]+\))?=(.*)$/;

/** An attribute's value from its aapt2 spelling: `"x" (Raw: "x")`, `true`, `@0x7f..`, `0x00000002`. */
export const attributeValue = (raw) => {
  const quoted = /^"(.*)" \(Raw: .*\)$/.exec(raw) ?? /^"(.*)"$/.exec(raw);
  return quoted ? quoted[1] : raw.trim();
};

/**
 * The element tree of an `aapt2 dump xmltree` listing: `{name, attrs, children}`.
 * Nesting is the indentation, which is the only structure the format has.
 */
export const parseXmlTree = (text) => {
  const root = { name: '#root', attrs: {}, children: [], depth: -1 };
  const stack = [root];
  let current = null;
  for (const line of text.split('\n')) {
    const element = ELEMENT.exec(line);
    if (element) {
      const depth = element[1].length;
      while (stack.length > 1 && stack.at(-1).depth >= depth) stack.pop();
      current = { name: element[2], attrs: {}, children: [], depth };
      stack.at(-1).children.push(current);
      stack.push(current);
      continue;
    }
    const attribute = ATTRIBUTE.exec(line);
    if (attribute && current) current.attrs[attribute[1]] = attributeValue(attribute[2]);
    // A text node (a <domain>'s host name) belongs to the element above it.
    const textNode = TEXT.exec(line);
    if (textNode && current) current.attrs.text = textNode[1];
  }
  return root;
};

/** Every element named `name` anywhere under `node`. */
export const findAll = (node, name) =>
  node.children.flatMap((child) => [
    ...(child.name === name ? [child] : []),
    ...findAll(child, name),
  ]);

const finding = (ruleId, file, severity, message) => ({ ruleId, file, line: 1, severity, message });

const isLauncher = (component) =>
  findAll(component, 'intent-filter').some(
    (filter) =>
      findAll(filter, 'action').some((a) => a.attrs.name === 'android.intent.action.MAIN') &&
      findAll(filter, 'category').some((c) => c.attrs.name === 'android.intent.category.LAUNCHER'),
  );

// Without an explicit android:exported, a component with an intent filter was
// exported by default before API 31. Treating the absence as exported is the
// reading that cannot miss one.
const isExported = (component) =>
  component.attrs.exported === 'true' ||
  (component.attrs.exported === undefined && findAll(component, 'intent-filter').length > 0);

const COMPONENT_RULES = {
  activity: 'MASTG-TEST-0364',
  service: 'MASTG-TEST-0365',
  receiver: 'MASTG-TEST-0366',
  provider: 'binaries/exported-provider',
};

/** Findings from the APK's manifest, its network security config and its signature. */
export const androidFindings = ({ manifest, nsc, signer, file, options }) => {
  const findings = [];
  const application = findAll(manifest, 'application')[0];
  if (!application) {
    return [
      finding(
        'binaries/android-manifest',
        file,
        'high',
        'the manifest has no <application> element: aapt2 read something that is not this app',
      ),
    ];
  }
  const app = application.attrs;
  if (app.debuggable === 'true') {
    findings.push(
      finding(
        'MASTG-TEST-0226',
        file,
        'critical',
        'android:debuggable is true: anyone with the device can attach a debugger to the release app',
      ),
    );
  }
  if (app.usesCleartextTraffic === 'true') {
    findings.push(
      finding(
        'MASTG-TEST-0235',
        file,
        'high',
        'android:usesCleartextTraffic is true: the release app may send traffic unencrypted',
      ),
    );
  }
  if (
    app.allowBackup !== 'false' &&
    app.fullBackupContent === undefined &&
    app.dataExtractionRules === undefined
  ) {
    findings.push(
      finding(
        'MASTG-TEST-0262',
        file,
        'medium',
        'backups are allowed with no backup rules: everything the app stores goes into device and cloud backups',
      ),
    );
  }
  for (const permission of findAll(manifest, 'uses-permission')) {
    const name = permission.attrs.name;
    if (DANGEROUS_PERMISSIONS.has(name) && !options.androidPermissions.includes(name)) {
      findings.push(
        finding(
          'MASTG-TEST-0254',
          file,
          'medium',
          `${name} is requested and not in binaries.androidPermissions: remove it, or list it with the reason the app needs it`,
        ),
      );
    }
  }
  for (const [kind, ruleId] of Object.entries(COMPONENT_RULES)) {
    for (const component of findAll(application, kind)) {
      const name = component.attrs.name;
      if (!isExported(component) || component.attrs.permission || isLauncher(component)) continue;
      if (options.exportedComponents.includes(name)) continue;
      findings.push(
        finding(
          ruleId,
          file,
          'medium',
          `${kind} ${name} is exported with no permission: any app on the device can reach it. Protect it, stop exporting it, or list it in binaries.exportedComponents with the reason`,
        ),
      );
    }
  }
  if (nsc) {
    for (const config of [...findAll(nsc, 'base-config'), ...findAll(nsc, 'domain-config')]) {
      if (config.attrs.cleartextTrafficPermitted === 'true') {
        const where =
          config.name === 'base-config'
            ? 'for every domain'
            : `for ${
                findAll(config, 'domain')
                  .map((d) => d.attrs.text ?? '(unnamed)')
                  .join(', ') || 'a domain'
              }`;
        findings.push(
          finding(
            'MASTG-TEST-0235',
            file,
            'high',
            `the network security config permits cleartext traffic ${where}`,
          ),
        );
      }
    }
    for (const certificates of findAll(nsc, 'certificates')) {
      if (certificates.attrs.src === 'user') {
        findings.push(
          finding(
            'MASTG-TEST-0286',
            file,
            'high',
            "the network security config trusts user-installed certificate authorities: anyone who can add one can read the app's TLS traffic",
          ),
        );
      }
    }
  }
  if (signer) {
    const scheme = (n) => new RegExp(`Verified using v${n} scheme[^:]*: true`).test(signer);
    if (!scheme(2) && !scheme(3)) {
      findings.push(
        finding(
          'MASTG-TEST-0224',
          file,
          'high',
          'the APK is signed with the v1 (JAR) scheme only, which Janus-class attacks defeat; sign with v2 or later',
        ),
      );
    }
    for (const [, size] of signer.matchAll(/key size \(bits\): (\d+)/g)) {
      if (Number(size) < 2048) {
        findings.push(
          finding(
            'MASTG-TEST-0225',
            file,
            'high',
            `a signing key is ${size} bits: below the 2048 bits MASTG requires`,
          ),
        );
      }
    }
  }
  return findings;
};

const WEAK_TLS = new Set(['TLSv1.0', 'TLSv1.1']);

/** Findings from the IPA's Info.plist and its provisioning profile's entitlements. */
export const iosFindings = ({ info, entitlements, file, options }) => {
  const findings = [];
  if (entitlements?.['get-task-allow'] === true) {
    findings.push(
      finding(
        'MASTG-TEST-0261',
        file,
        'critical',
        'get-task-allow is true: the build is debuggable, which also means App Store review will reject it',
      ),
    );
  }
  const ats = info?.NSAppTransportSecurity ?? {};
  for (const key of [
    'NSAllowsArbitraryLoads',
    'NSAllowsArbitraryLoadsInWebContent',
    'NSAllowsArbitraryLoadsForMedia',
  ]) {
    if (ats[key] === true) {
      findings.push(
        finding(
          'MASTG-TEST-0322',
          file,
          'high',
          `App Transport Security ${key} is true: cleartext and weak TLS are allowed app-wide`,
        ),
      );
    }
  }
  for (const [domain, exception] of Object.entries(ats.NSExceptionDomains ?? {})) {
    const insecure =
      exception.NSExceptionAllowsInsecureHTTPLoads === true ||
      exception.NSTemporaryExceptionAllowsInsecureHTTPLoads === true;
    if (insecure && !options.atsExceptionDomains.includes(domain)) {
      findings.push(
        finding(
          'MASTG-TEST-0322',
          file,
          'high',
          `App Transport Security allows cleartext HTTP to ${domain}, which is not in binaries.atsExceptionDomains`,
        ),
      );
    }
    const floor =
      exception.NSExceptionMinimumTLSVersion ?? exception.NSTemporaryExceptionMinimumTLSVersion;
    if (WEAK_TLS.has(floor)) {
      findings.push(
        finding(
          'MASTG-TEST-0342',
          file,
          'high',
          `App Transport Security lets ${domain} use ${floor}, below TLS 1.2`,
        ),
      );
    }
  }
  return findings;
};

/** Parses `--flag value` pairs; `--note` may repeat. */
export const parseArgs = (argv) => {
  const args = { notes: [] };
  for (let i = 0; i < argv.length; i += 2) {
    const [flag, value] = [argv[i], argv[i + 1]];
    if (!flag.startsWith('--') || value === undefined)
      throw new Error(`expected --flag value, got ${JSON.stringify(flag)}`);
    const key = flag.slice(2).replace(/-([a-z])/g, (_, c) => c.toUpperCase());
    if (key === 'note') args.notes.push(value);
    else args[key] = value;
  }
  return args;
};

/** Command-line entry; returns the exit code. */
export function main(
  argv = process.argv.slice(2),
  { log = console.log, error = console.error, env = process.env, read = readFileSync } = {},
) {
  let args;
  try {
    args = parseArgs(argv);
  } catch (cause) {
    error(`security-binaries.mjs: ${cause.message}`);
    return 2;
  }
  const options = load('security-settings.json', env).options.binaries;
  const text = (file) => (file ? read(file, 'utf8') : undefined);
  const json = (file) => (file ? JSON.parse(read(file, 'utf8')) : undefined);
  const findings = [];
  if (args.androidManifest) {
    findings.push(
      ...androidFindings({
        manifest: parseXmlTree(text(args.androidManifest)),
        nsc: args.androidNsc ? parseXmlTree(text(args.androidNsc)) : null,
        signer: text(args.androidSigner),
        file: args.androidFile ?? 'app.apk',
        options,
      }),
    );
  }
  if (args.iosInfo || args.iosEntitlements) {
    findings.push(
      ...iosFindings({
        info: json(args.iosInfo),
        entitlements: json(args.iosEntitlements),
        file: args.iosFile ?? 'app.ipa',
        options,
      }),
    );
  }
  const document = fromFindings('binaries', findings);
  // A note is a set of checks that did not run. The run is then not a clean
  // one, whatever else it found: executionSuccessful false is what makes the
  // verdict print "skipped: <note>" for it rather than "clean".
  if (args.notes.length) {
    document.runs[0].invocations[0] = {
      executionSuccessful: false,
      toolExecutionNotifications: args.notes.map((note) => ({
        level: 'note',
        message: { text: `skipped: ${note}` },
      })),
    };
  }
  log(JSON.stringify(document, null, 2));
  return 0;
}

if (isProgram(import.meta.url, process.argv[1])) process.exitCode = main();
