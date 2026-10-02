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
