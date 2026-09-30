#!/usr/bin/env node
// What the exported JavaScript bundle gives away. The bundle ships inside the
// app and anyone can read it, so every string in it is public:
//
//   - a build-time or release variable's name (anything .env.example names that
//     is not EXPO_PUBLIC_*; a repository with no .env.example declares none) means app code reached for a value it must not have
//   - a secret-shaped string is a credential shipped to every user
//   - an http:// URL is cleartext traffic (MASTG-TEST-0233 on Android,
//     MASTG-TEST-0321 on iOS) unless its host is in bundle.cleartextHosts
//   - with bundle.hosts set, any other https host is a note to look at
//
//     node lib/security-bundle.mjs <bundle>... > .security/bundle.sarif
//
// Hermes bytecode keeps its string table as plain bytes, so the printable runs
// of the file are the strings the app carries - the same thing `strings` would
// print, read here so the check does not depend on binutils being installed.
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fromFindings } from './security-sarif.mjs';
import { load } from './security-settings.mjs';
import { isProgram } from './is-program.mjs';

/** Printable ASCII runs of at least `min` bytes, as `strings` would find them. */
export const printableRuns = (buffer, min = 4) => {
  const runs = [];
  let start = -1;
  const close = (end) => {
    if (start >= 0 && end - start >= min) runs.push(buffer.toString('latin1', start, end));
    start = -1;
  };
  for (let i = 0; i < buffer.length; i += 1) {
    const printable = buffer[i] >= 0x20 && buffer[i] < 0x7f;
    if (printable && start < 0) start = i;
    if (!printable) close(i);
  }
  // A run that reaches the last byte has no terminator to close it.
  close(buffer.length);
  return runs;
};

/** Build-time and release variable names .env.example mentions: never allowed in the bundle. */
export const privateNames = (envExample) =>
  [...new Set(envExample.match(/\b[A-Z][A-Z0-9]*(?:_[A-Z0-9]+)+\b/g) ?? [])]
    .filter((name) => !name.startsWith('EXPO_PUBLIC_'))
    .sort();

// Credential shapes with a vendor prefix, so a match is a credential rather
// than a coincidence. A generic "long random string" rule would fire on every
// hash and identifier a bundle carries.
export const SECRET_SHAPES = [
  ['private-key', /-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----/],
  ['stripe-live-key', /\b[sr]k_live_[0-9A-Za-z]{16,}/],
  ['google-api-key', /\bAIza[0-9A-Za-z_-]{30,}/],
  ['aws-access-key', /\b(?:AKIA|ASIA)[0-9A-Z]{16}\b/],
  ['github-token', /\b(?:gh[pousr]_[0-9A-Za-z]{30,}|github_pat_[0-9A-Za-z_]{40,})/],
  ['slack-token', /\bxox[abprs]-[0-9A-Za-z-]{10,}/],
  ['anthropic-key', /\bsk-ant-[0-9A-Za-z_-]{20,}/],
  ['openai-key', /\bsk-(?:proj-)?[0-9A-Za-z_-]{32,}/],
];

const URL_PATTERN = /\b(https?):\/\/([A-Za-z0-9.-]+)/g;

// The export lands in a temporary directory, so an absolute path would be a
// different, meaningless location on every run. From `_expo/` down it is the
// path the bundle has inside the export, and the same on every machine.
/** A stable name for an exported bundle's location. */
export const bundleUri = (file) => {
  const at = file.indexOf('_expo/');
  return at >= 0 ? file.slice(at) : path.basename(file);
};

/** Every finding for one bundle's strings, as security-sarif.mjs findings. */
export const findingsFor = (file, strings, { names, hosts, cleartextHosts }) => {
  const findings = [];
  const text = strings.join('\n');
  for (const name of names) {
    if (new RegExp(`\\b${name}\\b`).test(text)) {
      findings.push({
        ruleId: 'bundle/private-variable-name',
        file,
        line: 1,
        severity: 'high',
        message: `${name} is a build-time or release variable, and its name is in the shipped bundle: app code read it, so its value may be there too`,
      });
    }
  }
  for (const [rule, pattern] of SECRET_SHAPES) {
    if (pattern.test(text)) {
      findings.push({
        ruleId: `bundle/${rule}`,
        file,
        line: 1,
        severity: 'critical',
        message: `a ${rule} shaped string is in the shipped bundle, readable by every user`,
      });
    }
  }
  const seen = new Set();
  for (const [, scheme, rawHost] of text.matchAll(URL_PATTERN)) {
    const host = rawHost.toLowerCase().replace(/\.$/, '');
    const key = `${scheme}://${host}`;
    if (seen.has(key)) continue;
    seen.add(key);
    if (scheme === 'http' && !cleartextHosts.includes(host)) {
      findings.push({
        ruleId: 'MASTG-TEST-0233',
        file,
        line: 1,
        severity: 'medium',
        message: `http://${host} is a cleartext URL in the shipped bundle (MASTG-TEST-0233, MASTG-TEST-0321). Use https, or list the host in bundle.cleartextHosts with the reason`,
      });
    } else if (scheme === 'https' && hosts.length > 0 && !hosts.includes(host)) {
      findings.push({
        ruleId: 'bundle/unlisted-host',
        file,
        line: 1,
        severity: 'low',
        message: `${host} is not in bundle.hosts: a new endpoint in the shipped app, or a string to add to the list`,
      });
    }
  }
  return findings;
};

/**
 * A file's text, or '' when the repository has none: an app with no
 * .env.example declares no build-time names, so none can leak by name.
 */
export const readOptional = (read, file) => {
  try {
    return read(file, 'utf8');
  } catch (error) {
    if (error.code === 'ENOENT') return '';
    throw error;
  }
};

/** Command-line entry; returns the exit code. */
export function main(
  argv = process.argv.slice(2),
  { log = console.log, error = console.error, env = process.env, read = readFileSync } = {},
) {
  if (argv.length === 0) {
    error('usage: security-bundle.mjs <bundle>...');
    return 2;
  }
  const settings = load('security-settings.json', env);
  const { hosts, cleartextHosts } = settings.options.bundle;
  const names = privateNames(readOptional(read, '.env.example'));
  const findings = argv.flatMap((file) =>
    findingsFor(bundleUri(file), printableRuns(read(file)), {
      names,
      hosts,
      cleartextHosts,
    }),
  );
  log(JSON.stringify(fromFindings('bundle', findings), null, 2));
  return 0;
}

if (isProgram(import.meta.url, process.argv[1])) process.exitCode = main();
