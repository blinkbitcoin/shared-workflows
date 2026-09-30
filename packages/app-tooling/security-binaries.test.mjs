import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import {
  androidFindings,
  attributeValue,
  findAll,
  iosFindings,
  main,
  parseArgs,
  parseXmlTree,
} from './lib/security-binaries.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const NS = 'http://schemas.android.com/apk/res/android';
const OPTIONS = { androidPermissions: [], exportedComponents: [], atsExceptionDomains: [] };
const rules = (findings) => findings.map((f) => f.ruleId);

// The shape `aapt2 dump xmltree` prints, trimmed to what the checks read.
const attr = (depth, name, value) => `${' '.repeat(depth)}A: ${NS}:${name}(0x01010000)=${value}`;
const manifest = ({ application = [], permissions = [], components = [] } = {}) =>
  [
    'N: android=http://schemas.android.com/apk/res/android (line=2)',
    '  E: manifest (line=2)',
    '    A: package="com.example.app" (Raw: "com.example.app")',
    ...permissions.flatMap((name) => [
      '      E: uses-permission (line=3)',
      attr(8, 'name', `"${name}" (Raw: "${name}")`),
    ]),
    '      E: application (line=5)',
    ...application.map(([name, value]) => attr(8, name, value)),
    ...components,
  ].join('\n');

const SAFE_APP = [
  ['allowBackup', 'true'],
  ['fullBackupContent', '@0x7f140006'],
];
const SIGNED_V2 = [
  'Verified using v1 scheme (JAR signing): false',
  'Verified using v2 scheme (APK Signature Scheme v2): true',
  'Verified using v3 scheme (APK Signature Scheme v3): true',
  'Signer #1 key size (bits): 2048',
].join('\n');

const android = (overrides) =>
  androidFindings({
    manifest: parseXmlTree(manifest({ application: SAFE_APP })),
    nsc: null,
    signer: SIGNED_V2,
    file: 'app.apk',
    options: OPTIONS,
    ...overrides,
  });

test('attributeValue reads every spelling aapt2 uses', () => {
  assert.equal(attributeValue('"x" (Raw: "x")'), 'x');
  assert.equal(attributeValue('"y"'), 'y');
  assert.equal(attributeValue('true '), 'true');
  assert.equal(attributeValue('@0x7f140006'), '@0x7f140006');
});

test('parseXmlTree rebuilds the nesting from indentation, text nodes included', () => {
  const tree = parseXmlTree(
    [
      'N: android=x (line=1)',
      '  E: a (line=1)',
      '    A: plain="1" (Raw: "1")',
      '      E: b (line=2)',
      "        T: 'hello'",
      '      E: c (line=3)',
      '  E: d (line=4)',
      'garbage line',
    ].join('\n'),
  );
  assert.deepEqual(
    tree.children.map((n) => n.name),
    ['a', 'd'],
  );
  assert.equal(tree.children[0].attrs.plain, '1');
  assert.deepEqual(
    tree.children[0].children.map((n) => n.name),
    ['b', 'c'],
  );
  assert.equal(findAll(tree, 'b')[0].attrs.text, 'hello');
  // An attribute or text before any element has nowhere to go and is dropped.
  assert.deepEqual(parseXmlTree("A: x=1\nT: 'y'").children, []);
});

test('a safe release manifest has no findings', () => {
  assert.deepEqual(android(), []);
});

test('a manifest with no application element is reported, not passed', () => {
  const findings = android({ manifest: parseXmlTree('N: x\n  E: manifest (line=1)') });
  assert.deepEqual(rules(findings), ['binaries/android-manifest']);
});

test('debuggable is critical (MASTG-TEST-0226) and cleartext is high (MASTG-TEST-0235)', () => {
  const findings = android({
    manifest: parseXmlTree(
      manifest({
        application: [...SAFE_APP, ['debuggable', 'true'], ['usesCleartextTraffic', 'true']],
      }),
    ),
  });
  assert.deepEqual(rules(findings), ['MASTG-TEST-0226', 'MASTG-TEST-0235']);
  assert.deepEqual(
    findings.map((f) => f.severity),
    ['critical', 'high'],
  );
});

test('backups with no rules are MASTG-TEST-0262; rules or allowBackup=false clear it', () => {
  const tree = (application) => parseXmlTree(manifest({ application }));
  assert.deepEqual(rules(android({ manifest: tree([['allowBackup', 'true']]) })), [
    'MASTG-TEST-0262',
  ]);
  assert.deepEqual(rules(android({ manifest: tree([]) })), ['MASTG-TEST-0262']);
  assert.deepEqual(android({ manifest: tree([['allowBackup', 'false']]) }), []);
  assert.deepEqual(android({ manifest: tree([['dataExtractionRules', '@0x7f1']]) }), []);
});

test('a dangerous permission is medium unless allowlisted (MASTG-TEST-0254)', () => {
  const tree = parseXmlTree(
    manifest({
      application: SAFE_APP,
      permissions: [
        'android.permission.INTERNET',
        'android.permission.CAMERA',
        'android.permission.SYSTEM_ALERT_WINDOW',
      ],
    }),
  );
  assert.deepEqual(rules(android({ manifest: tree })), ['MASTG-TEST-0254', 'MASTG-TEST-0254']);
  const allowed = { ...OPTIONS, androidPermissions: ['android.permission.CAMERA'] };
  const findings = android({ manifest: tree, options: allowed });
  assert.equal(findings.length, 1);
  assert.match(findings[0].message, /SYSTEM_ALERT_WINDOW/);
});

test('an exported component with no permission is reported under its own MASTG test', () => {
  const component = (kind, name, extra = []) => [
    `          E: ${kind} (line=9)`,
    attr(12, 'name', `"${name}" (Raw: "${name}")`),
    ...extra,
  ];
  const exported = attr(12, 'exported', 'true');
  const filter = (action, category) => [
    '              E: intent-filter (line=10)',
    '                  E: action (line=11)',
    attr(20, 'name', `"${action}" (Raw: "${action}")`),
    '                  E: category (line=12)',
    attr(20, 'name', `"${category}" (Raw: "${category}")`),
  ];
  const tree = parseXmlTree(
    manifest({
      application: SAFE_APP,
      components: [
        ...component('activity', 'app.Main', [
          exported,
          ...filter('android.intent.action.MAIN', 'android.intent.category.LAUNCHER'),
        ]),
        ...component('activity', 'app.Share', [exported]),
        // No explicit exported, but an intent filter: exported before API 31.
        ...component('service', 'app.Sync', filter('app.SYNC', 'android.intent.category.DEFAULT')),
        ...component('receiver', 'app.Boot', [
          exported,
          attr(12, 'permission', '"android.permission.DUMP"'),
        ]),
        ...component('receiver', 'app.Push', [exported]),
        ...component('provider', 'app.Files', [exported]),
        ...component('provider', 'app.Private', [attr(12, 'exported', 'false')]),
        // A launcher-looking filter missing its category is not the launcher.
        ...component('activity', 'app.Half', [
          exported,
          ...filter('android.intent.action.MAIN', 'android.intent.category.DEFAULT'),
        ]),
      ],
    }),
  );
  const findings = android({ manifest: tree });
  assert.deepEqual(
    findings.map((f) => `${f.ruleId} ${f.message.split(' ')[1]}`),
    [
      'MASTG-TEST-0364 app.Share',
      'MASTG-TEST-0364 app.Half',
      'MASTG-TEST-0365 app.Sync',
      'MASTG-TEST-0366 app.Push',
      'binaries/exported-provider app.Files',
    ],
  );
  const allowed = {
    ...OPTIONS,
    exportedComponents: ['app.Share', 'app.Half', 'app.Sync', 'app.Push', 'app.Files'],
  };
  assert.deepEqual(android({ manifest: tree, options: allowed }), []);
});

test('the network security config: cleartext is MASTG-TEST-0235, user CAs MASTG-TEST-0286', () => {
  const nsc = parseXmlTree(
    [
      'N: x',
      '  E: network-security-config (line=1)',
      '      E: base-config (line=2)',
      '        A: cleartextTrafficPermitted=true',
      '          E: trust-anchors (line=3)',
      '              E: certificates (line=4)',
      '                A: src="user" (Raw: "user")',
      '              E: certificates (line=5)',
      '                A: src="system" (Raw: "system")',
      '      E: domain-config (line=6)',
      '        A: cleartextTrafficPermitted=true',
      '          E: domain (line=7)',
      "            T: 'legacy.example.com'",
      '      E: domain-config (line=8)',
      '        A: cleartextTrafficPermitted=true',
      '      E: domain-config (line=9)',
      '        A: cleartextTrafficPermitted=true',
      '          E: domain (line=10)',
      '      E: domain-config (line=11)',
      '        A: cleartextTrafficPermitted=false',
    ].join('\n'),
  );
  const findings = android({ nsc });
  assert.deepEqual(rules(findings), [
    'MASTG-TEST-0235',
    'MASTG-TEST-0235',
    'MASTG-TEST-0235',
    'MASTG-TEST-0235',
    'MASTG-TEST-0286',
  ]);
  assert.match(findings[0].message, /for every domain/);
  assert.match(findings[1].message, /for legacy\.example\.com/);
  assert.match(findings[2].message, /for a domain$/);
  assert.match(findings[3].message, /for \(unnamed\)/);
});

test('v1-only signing is MASTG-TEST-0224 and a short key MASTG-TEST-0225', () => {
  const signer = [
    'Verified using v1 scheme (JAR signing): true',
    'Verified using v2 scheme (APK Signature Scheme v2): false',
    'Verified using v3 scheme (APK Signature Scheme v3): false',
    'Signer #1 key size (bits): 1024',
    'Signer #2 key size (bits): 4096',
  ].join('\n');
  assert.deepEqual(rules(android({ signer })), ['MASTG-TEST-0224', 'MASTG-TEST-0225']);
  assert.deepEqual(
    android({ signer: 'Verified using v3 scheme (APK Signature Scheme v3): true' }),
    [],
  );
  assert.deepEqual(android({ signer: undefined }), []);
});

test('iOS: get-task-allow is critical (MASTG-TEST-0261)', () => {
  const findings = iosFindings({
    info: {},
    entitlements: { 'get-task-allow': true },
    file: 'a.ipa',
    options: OPTIONS,
  });
  assert.deepEqual(rules(findings), ['MASTG-TEST-0261']);
  assert.equal(findings[0].severity, 'critical');
  assert.deepEqual(
    iosFindings({
      info: {},
      entitlements: { 'get-task-allow': false },
      file: 'a.ipa',
      options: OPTIONS,
    }),
    [],
  );
  assert.deepEqual(iosFindings({ file: 'a.ipa', options: OPTIONS }), []);
});

test('iOS: App Transport Security exceptions (MASTG-TEST-0322, MASTG-TEST-0342)', () => {
  const info = {
    NSAppTransportSecurity: {
      NSAllowsArbitraryLoads: true,
      NSAllowsArbitraryLoadsInWebContent: true,
      NSAllowsArbitraryLoadsForMedia: false,
      NSAllowsLocalNetworking: true,
      NSExceptionDomains: {
        'legacy.example.com': { NSExceptionAllowsInsecureHTTPLoads: true },
        'listed.example.com': { NSTemporaryExceptionAllowsInsecureHTTPLoads: true },
        'old-tls.example.com': { NSExceptionMinimumTLSVersion: 'TLSv1.0' },
        'older.example.com': { NSTemporaryExceptionMinimumTLSVersion: 'TLSv1.1' },
        'fine.example.com': { NSExceptionMinimumTLSVersion: 'TLSv1.2' },
      },
    },
  };
  const findings = iosFindings({
    info,
    file: 'a.ipa',
    options: { ...OPTIONS, atsExceptionDomains: ['listed.example.com'] },
  });
  assert.deepEqual(rules(findings), [
    'MASTG-TEST-0322',
    'MASTG-TEST-0322',
    'MASTG-TEST-0322',
    'MASTG-TEST-0342',
    'MASTG-TEST-0342',
  ]);
  assert.match(findings[2].message, /cleartext HTTP to legacy\.example\.com, which is not in/);
});

test('parseArgs reads flag pairs and repeats --note', () => {
  assert.deepEqual(parseArgs(['--android-file', 'a.apk', '--note', 'one', '--note', 'two']), {
    androidFile: 'a.apk',
    notes: ['one', 'two'],
  });
  assert.throws(() => parseArgs(['stray']), /expected --flag value, got "stray"/);
  assert.throws(() => parseArgs(['--ios-info']), /expected --flag value/);
});

const withFiles = (files, fn) => {
  const dir = mkdtempSync(path.join(tmpdir(), 'binaries-'));
  try {
    const paths = Object.fromEntries(
      Object.entries(files).map(([name, content]) => {
        const file = path.join(dir, name);
        writeFileSync(file, content);
        return [name, file];
      }),
    );
    return fn(paths, dir);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
};

test('main runs both platforms and writes one SARIF document', () => {
  withFiles(
    {
      'manifest.txt': manifest({ application: [...SAFE_APP, ['debuggable', 'true']] }),
      'nsc.txt':
        'N: x\n  E: network-security-config (line=1)\n      E: base-config (line=2)\n        A: cleartextTrafficPermitted=true',
      'signer.txt': SIGNED_V2,
      'info.json': JSON.stringify({ NSAppTransportSecurity: { NSAllowsArbitraryLoads: true } }),
      'entitlements.json': JSON.stringify({ 'get-task-allow': true }),
    },
    (f, dir) => {
      const out = [];
      const code = main(
        [
          '--android-manifest',
          f['manifest.txt'],
          '--android-nsc',
          f['nsc.txt'],
          '--android-signer',
          f['signer.txt'],
          '--ios-info',
          f['info.json'],
          '--ios-entitlements',
          f['entitlements.json'],
        ],
        { log: (l) => out.push(l), env: { SECURITY_SETTINGS_FILE: path.join(dir, 'none.json') } },
      );
      assert.equal(code, 0);
      const run = JSON.parse(out[0]).runs[0];
      assert.equal(run.invocations[0].executionSuccessful, true);
      assert.deepEqual(rules(run.results), [
        'MASTG-TEST-0226',
        'MASTG-TEST-0235',
        'MASTG-TEST-0261',
        'MASTG-TEST-0322',
      ]);
      // Without a name given, the location falls back to a generic one.
      assert.equal(run.results[0].locations[0].physicalLocation.artifactLocation.uri, 'app.apk');
      assert.equal(run.results[2].locations[0].physicalLocation.artifactLocation.uri, 'app.ipa');
    },
  );
});

test('a note means part of the checks did not run: the run is skipped, not clean', () => {
  withFiles({ 'info.json': '{}' }, (f, dir) => {
    const out = [];
    main(
      [
        '--ios-entitlements',
        f['info.json'],
        '--ios-file',
        'x.ipa',
        '--note',
        'aapt2 is not installed: those checks did not run',
      ],
      {
        log: (l) => out.push(l),
        env: { SECURITY_SETTINGS_FILE: path.join(dir, 'none.json') },
      },
    );
    const [invocation] = JSON.parse(out[0]).runs[0].invocations;
    assert.equal(invocation.executionSuccessful, false);
    assert.match(
      invocation.toolExecutionNotifications[0].message.text,
      /^skipped: aapt2 is not installed/,
    );
  });
});

test('main with no evidence at all is a clean, empty run; a bad flag exits 2', () => {
  const out = [];
  const errors = [];
  assert.equal(
    main([], {
      log: (l) => out.push(l),
      env: { SECURITY_SETTINGS_FILE: '/nonexistent/policy.json' },
    }),
    0,
  );
  assert.deepEqual(JSON.parse(out[0]).runs[0].results, []);
  assert.equal(main(['oops'], { error: (l) => errors.push(l) }), 2);
  assert.match(errors[0], /^security-binaries\.mjs: expected --flag value/);
});

test('runs as a script', () => {
  const run = spawnSync(process.execPath, [path.join(here, 'lib', 'security-binaries.mjs')], {
    encoding: 'utf8',
    cwd: here,
    env: process.env,
  });
  assert.equal(run.status, 0, run.stderr);
  assert.equal(JSON.parse(run.stdout).runs[0].tool.driver.name, 'binaries');
});

test('main with a manifest and no signer output still checks the manifest', () => {
  withFiles({ 'manifest.txt': manifest({ application: SAFE_APP }) }, (f, dir) => {
    const out = [];
    main(['--android-manifest', f['manifest.txt'], '--android-file', 'x.apk'], {
      log: (l) => out.push(l),
      env: { SECURITY_SETTINGS_FILE: path.join(dir, 'none.json') },
    });
    assert.deepEqual(JSON.parse(out[0]).runs[0].results, []);
  });
});
