// The one configuration file of this family: `app-tooling.json` at the
// repository root, a section per program. A rule that belongs to a repository
// - which files are sources, which paths are architecture - lives there as
// data, and the make recipe stays one short call:
//
//   {
//     "testSiblings": { "sources": {...}, "exclude": [...], "mirror": {...} },
//     "docs": { "architecture": [...], "allowTargetNames": {...} },
//     "appSuites": { "skip": {...} }
//   }
//
// The file is optional; a missing one reads as no section. One that is there
// is held to exactly this shape: a key this version does not know is an error,
// not something to skip, because `excludes` written for `exclude` would
// otherwise silently check nothing. A program's flags override its section,
// field by field.
import path from 'node:path';

export const CONFIG_FILE = 'app-tooling.json';

/** The sections the file may hold, and the keys each may hold. */
export const SECTIONS = {
  testSiblings: ['sources', 'exclude', 'mirror'],
  docs: ['architecture', 'allowTargetNames'],
  appSuites: ['skip'],
  ports: ['base', 'services', 'apiPath', 'allow', 'retired'],
  prebuild: ['scenarios', 'exclude', 'command'],
  testScripts: ['sources', 'tests'],
};

/** A configuration file that is there and wrong; a program exits 2 on one. */
export class ConfigError extends Error {}

const isObject = (value) => value !== null && typeof value === 'object' && !Array.isArray(value);

/**
 * The section `name` of `app-tooling.json` under `root`, or null when the file
 * or the section is absent. `read(file)` returns the text or null. Throws a
 * ConfigError naming the file and what is wrong with it.
 */
export function readSection(root, name, read) {
  const file = path.join(root, CONFIG_FILE);
  const text = read(file);
  if (text === null) return null;
  const fail = (reason) => {
    throw new ConfigError(`${CONFIG_FILE}: ${reason}`);
  };
  let config;
  try {
    config = JSON.parse(text);
  } catch (e) {
    fail(`not valid JSON: ${e.message}`);
  }
  if (!isObject(config)) fail('the top level must be an object of sections');
  for (const key of Object.keys(config)) {
    if (!(key in SECTIONS)) fail(`unknown section "${key}"; the sections are ${Object.keys(SECTIONS).join(', ')}`);
  }
  const section = config[name];
  if (section === undefined) return null;
  if (!isObject(section)) fail(`"${name}" must be an object`);
  for (const key of Object.keys(section)) {
    if (!SECTIONS[name].includes(key)) fail(`unknown key "${name}.${key}"; "${name}" takes ${SECTIONS[name].join(', ')}`);
  }
  return section;
}

/** `value` as a list of non-empty strings, or a ConfigError naming `where`. */
export function stringList(value, where) {
  if (!Array.isArray(value) || !value.every((item) => typeof item === 'string' && item !== '')) {
    throw new ConfigError(`${CONFIG_FILE}: "${where}" must be a list of non-empty strings`);
  }
  return value;
}

/** `value` as an object of non-empty strings, or a ConfigError naming `where`. */
export function stringMap(value, where) {
  if (!isObject(value) || !Object.values(value).every((item) => typeof item === 'string' && item.trim() !== '')) {
    throw new ConfigError(`${CONFIG_FILE}: "${where}" must be an object of non-empty strings`);
  }
  return value;
}

/** `value` as a port table (base, services, apiPath), or a ConfigError naming the first thing wrong. */
export function portTable(section) {
  const table = {};
  if (section === null) return table;
  const fail = (reason) => {
    throw new ConfigError(`${CONFIG_FILE}: ${reason}`);
  };
  if (section.base !== undefined) {
    if (!Number.isInteger(section.base) || section.base < 1 || section.base > 65535) fail('"ports.base" must be a port number (1-65535)');
    table.base = section.base;
  }
  if (section.apiPath !== undefined) {
    if (typeof section.apiPath !== 'string' || !section.apiPath.startsWith('/')) fail('"ports.apiPath" must be a path starting with /');
    table.apiPath = section.apiPath;
  }
  if (section.services !== undefined) {
    if (!isObject(section.services) || Object.keys(section.services).length === 0) fail('"ports.services" must be an object with at least one service');
    for (const [key, service] of Object.entries(section.services)) {
      const ok =
        isObject(service) &&
        Number.isInteger(service.offset) &&
        service.offset >= 1 &&
        typeof service.env === 'string' &&
        /^[A-Z][A-Z0-9_]*$/.test(service.env) &&
        typeof service.what === 'string';
      if (!ok) fail(`"ports.services.${key}" needs an integer offset (1 or more), an env variable name in capitals, and what listens there`);
    }
    const offsets = Object.values(section.services).map((service) => service.offset);
    const names = Object.values(section.services).map((service) => service.env);
    if (new Set(offsets).size !== offsets.length) fail('"ports.services" gives two services the same offset');
    if (new Set(names).size !== names.length) fail('"ports.services" gives two services the same env variable');
    table.services = section.services;
  }
  return table;
}

/** The assertion forms a prebuild scenario holds: the key naming what is asserted, and what it asserts. */
export const PREBUILD_ASSERTIONS = {
  contains: 'a file matching `file` holds this text',
  absent: 'no file matching `file` holds this text',
  pattern: 'a file matching `file` has a match for this regular expression (`s` flag: `.` crosses lines)',
  exists: 'a path matching this pattern exists',
};

/**
 * The `prebuild` section checked and filled in: `{ exclude, command, scenarios }`, each scenario
 * `{ name, label, env, assertions }` and each assertion `{ kind, value, file, message }`. A ConfigError
 * names the first thing wrong, and says what the key takes.
 */
export function prebuildConfig(section) {
  const fail = (reason) => {
    throw new ConfigError(`${CONFIG_FILE}: ${reason}`);
  };
  if (section === null) fail('no "prebuild" section: name at least one scenario');
  const exclude = section.exclude === undefined ? [] : stringList(section.exclude, 'prebuild.exclude');
  const command =
    section.command === undefined ? ['./node_modules/.bin/expo', 'prebuild', '--platform', 'all', '--clean', '--no-install'] : stringList(section.command, 'prebuild.command');
  if (command.length === 0) fail('"prebuild.command" must name a program');
  if (!isObject(section.scenarios) || Object.keys(section.scenarios).length === 0) {
    fail('"prebuild.scenarios" must be an object with at least one scenario');
  }
  const scenarios = Object.entries(section.scenarios).map(([name, scenario]) => {
    const where = `prebuild.scenarios.${name}`;
    if (!isObject(scenario)) fail(`"${where}" must be an object`);
    for (const key of Object.keys(scenario)) {
      if (!['label', 'env', 'assert'].includes(key)) fail(`unknown key "${where}.${key}"; a scenario takes label, env, assert`);
    }
    if (scenario.label !== undefined && typeof scenario.label !== 'string') fail(`"${where}.label" must be a string`);
    const env = scenario.env === undefined ? {} : stringMap(scenario.env, `${where}.env`);
    if (!Array.isArray(scenario.assert) || scenario.assert.length === 0) fail(`"${where}.assert" must be a list with at least one assertion`);
    const assertions = scenario.assert.map((assertion, index) => {
      const at = `${where}.assert[${index}]`;
      if (!isObject(assertion)) fail(`"${at}" must be an object`);
      const kinds = Object.keys(PREBUILD_ASSERTIONS).filter((kind) => kind in assertion);
      if (kinds.length !== 1) fail(`"${at}" needs exactly one of ${Object.keys(PREBUILD_ASSERTIONS).join(', ')}`);
      const [kind] = kinds;
      for (const key of Object.keys(assertion)) {
        if (!(kind === 'exists' ? [kind, 'message'] : [kind, 'file', 'message']).includes(key)) fail(`unknown key "${at}.${key}"; "${kind}" takes ${kind}${kind === 'exists' ? '' : ', file'}, message`);
      }
      if (typeof assertion[kind] !== 'string' || assertion[kind] === '') fail(`"${at}.${kind}" must be a non-empty string`);
      if (kind === 'pattern') {
        try {
          new RegExp(assertion.pattern, 's');
        } catch (e) {
          fail(`"${at}.pattern" is not a regular expression: ${e.message}`);
        }
      }
      if (kind !== 'exists' && (typeof assertion.file !== 'string' || assertion.file === '')) fail(`"${at}.file" must name the files to look in`);
      if (assertion.message !== undefined && typeof assertion.message !== 'string') fail(`"${at}.message" must be a string`);
      return { kind, value: assertion[kind], file: assertion.file ?? null, message: assertion.message ?? null };
    });
    return { name, label: scenario.label ?? name, env, assertions };
  });
  return { exclude, command, scenarios };
}

/**
 * The `testScripts` section with its defaults: `{ sources, tests }`, the path patterns of the
 * script modules held to 100% coverage and of the test files that run them.
 */
export function testScriptsConfig(section) {
  const sources = section?.sources === undefined ? ['scripts/**/*.mjs'] : stringList(section.sources, 'testScripts.sources');
  const tests = section?.tests === undefined ? ['scripts/**/*.test.mjs'] : stringList(section.tests, 'testScripts.tests');
  if (sources.length === 0) throw new ConfigError(`${CONFIG_FILE}: "testScripts.sources" must name at least one path pattern`);
  if (tests.length === 0) throw new ConfigError(`${CONFIG_FILE}: "testScripts.tests" must name at least one path pattern`);
  return { sources, tests };
}
