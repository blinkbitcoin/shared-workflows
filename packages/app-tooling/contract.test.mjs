// contract.json against contract.schema.json, and against this repository's
// own workflows.
//
// The package ships no dependencies and the toolchain pins no JSON Schema
// validator, so the validator is the few lines below: the subset of draft
// 2020-12 the schema uses, and a test that the schema uses nothing else - a
// keyword this validator does not know would otherwise be ignored in silence.
import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { test } from 'node:test';

const read = (file) => JSON.parse(readFileSync(new URL(file, import.meta.url), 'utf8'));
const CONTRACT = read('./contract.json');
const SCHEMA = read('./contract.schema.json');

// Keywords that only describe: they never make an instance invalid.
const ANNOTATIONS = new Set(['$schema', '$id', '$comment', 'title', 'description']);
// Keywords whose value is a map of name to schema, or one schema, or a list of them.
const SCHEMA_MAPS = new Set(['properties', '$defs']);
const ONE_SCHEMA = new Set(['items', 'additionalProperties', 'propertyNames', 'if', 'then']);
const SCHEMA_LISTS = new Set(['anyOf', 'allOf']);
const ASSERTIONS = new Set(['type', 'enum', 'const', 'required', 'minProperties', 'minItems', 'uniqueItems', 'minLength', 'pattern', '$ref']);

const typeOf = (value) => (value === null ? 'null' : Array.isArray(value) ? 'array' : typeof value);
const equal = (a, b) => JSON.stringify(a) === JSON.stringify(b);

/** Every problem with `value` against `schema`, as `<path>: <what>` lines; empty when it is valid. */
function validate(value, schema, root = schema, at = '$') {
  if (schema.$ref) return validate(value, root.$defs[schema.$ref.replace('#/$defs/', '')], root, at);
  const problems = [];
  const type = typeOf(value);
  if (schema.type && schema.type !== type) return [`${at}: is ${type}, not ${schema.type}`];
  if (schema.enum && !schema.enum.some((option) => equal(option, value))) problems.push(`${at}: ${JSON.stringify(value)} is not one of ${schema.enum.join(', ')}`);
  if ('const' in schema && !equal(schema.const, value)) problems.push(`${at}: must be ${JSON.stringify(schema.const)}`);
  if (schema.anyOf && schema.anyOf.every((option) => validate(value, option, root, at).length > 0)) problems.push(`${at}: matches none of its allowed shapes`);
  for (const part of schema.allOf ?? []) problems.push(...validate(value, part, root, at));
  if (schema.if && validate(value, schema.if, root, at).length === 0) problems.push(...validate(value, schema.then, root, at));
  if (type === 'string') {
    if (value.length < (schema.minLength ?? 0)) problems.push(`${at}: shorter than ${schema.minLength}`);
    if (schema.pattern && !new RegExp(schema.pattern, 'u').test(value)) problems.push(`${at}: does not match ${schema.pattern}`);
  }
  if (type === 'array') {
    if (value.length < (schema.minItems ?? 0)) problems.push(`${at}: fewer than ${schema.minItems} items`);
    if (schema.uniqueItems && new Set(value.map((item) => JSON.stringify(item))).size !== value.length) problems.push(`${at}: repeats an item`);
    if (schema.items) value.forEach((item, i) => problems.push(...validate(item, schema.items, root, `${at}[${i}]`)));
  }
  if (type === 'object') {
    const keys = Object.keys(value);
    if (keys.length < (schema.minProperties ?? 0)) problems.push(`${at}: fewer than ${schema.minProperties} properties`);
    for (const key of schema.required ?? []) if (!(key in value)) problems.push(`${at}: has no ${key}`);
    for (const key of keys) {
      if (schema.propertyNames) problems.push(...validate(key, schema.propertyNames, root, `${at} key ${key}`));
      const own = schema.properties?.[key];
      if (own) problems.push(...validate(value[key], own, root, `${at}.${key}`));
      else if (schema.additionalProperties === false) problems.push(`${at}: unknown property ${key}`);
      else if (schema.additionalProperties) problems.push(...validate(value[key], schema.additionalProperties, root, `${at}.${key}`));
    }
  }
  return problems;
}

/** Every keyword the schema uses, at any depth. */
function keywords(schema, found = new Set()) {
  for (const [key, value] of Object.entries(schema)) {
    found.add(key);
    if (SCHEMA_MAPS.has(key)) for (const sub of Object.values(value)) keywords(sub, found);
    if (ONE_SCHEMA.has(key) && typeof value === 'object') keywords(value, found);
    if (SCHEMA_LISTS.has(key)) for (const sub of value) keywords(sub, found);
  }
  return found;
}

/** The contract with one change made to a copy. */
const mutated = (change) => {
  const copy = structuredClone(CONTRACT);
  change(copy);
  return copy;
};
const problemsOf = (contract) => validate(contract, SCHEMA);

test('the schema uses only the keywords this validator checks', () => {
  const known = new Set([...ANNOTATIONS, ...SCHEMA_MAPS, ...ONE_SCHEMA, ...SCHEMA_LISTS, ...ASSERTIONS]);
  const unknown = [...keywords(SCHEMA)].filter((key) => !known.has(key));
  assert.deepEqual(unknown, []);
  assert.equal(SCHEMA.$schema, 'https://json-schema.org/draft/2020-12/schema');
});

test('contract.json points at its schema and is valid against it', () => {
  assert.equal(CONTRACT.$schema, './contract.schema.json');
  assert.deepEqual(problemsOf(CONTRACT), []);
});

test('a requirement with no kind, an unknown kind, or a wrong type is malformed', () => {
  assert.ok(problemsOf(mutated((c) => delete c.requirements[0].kind)).includes('$.requirements[0]: has no kind'));
  assert.deepEqual(problemsOf(mutated((c) => (c.requirements[0].kind = 'script-or-dep'))), [
    `$.requirements[0].kind: "script-or-dep" is not one of ${SCHEMA.$defs.kind.enum.join(', ')}`,
  ]);
  assert.deepEqual(problemsOf(mutated((c) => (c.requirements[0].defaultOn = 'true'))), ['$.requirements[0].defaultOn: is string, not boolean']);
  assert.deepEqual(problemsOf(mutated((c) => (c.requirements[0].target = 42))), ['$.requirements[0].target: matches none of its allowed shapes']);
  assert.deepEqual(problemsOf(mutated((c) => (c.requirements[0].target = []))), ['$.requirements[0].target: matches none of its allowed shapes']);
  assert.deepEqual(problemsOf(mutated((c) => (c.requirements = {}))), ['$.requirements: is object, not array']);
});

test('a requirement naming a profile the contract does not have is malformed', () => {
  assert.deepEqual(problemsOf(mutated((c) => (c.requirements[0].profile = 'lint'))), [
    `$.requirements[0].profile: "lint" is not one of ${SCHEMA.$defs.profileName.enum.join(', ')}`,
  ]);
});

test('every other field a requirement can carry is held to its shape', () => {
  const one = (change) => problemsOf(mutated((c) => change(c.requirements[0])));
  assert.deepEqual(one((r) => (r.toggle = 'check.yml')), ['$.requirements[0].toggle: matches none of its allowed shapes']);
  assert.deepEqual(one((r) => (r.severity = 'fatal')), ['$.requirements[0].severity: "fatal" is not one of required, degrades, optional']);
  assert.deepEqual(one((r) => (r.stack = 'flutter')), ['$.requirements[0].stack: "flutter" is not one of expo, bare']);
  assert.deepEqual(one((r) => (r.toggleValue = 'name')), ['$.requirements[0].toggleValue: must be "script-name"']);
  assert.deepEqual(one((r) => (r.workflow = ['check.yml', 'check.yml'])), ['$.requirements[0].workflow: repeats an item']);
  assert.deepEqual(one((r) => (r.workflow = ['check.yaml'])), ['$.requirements[0].workflow[0]: does not match ^[a-z0-9-]+\\.yml$']);
  assert.deepEqual(one((r) => (r.workflow = [])), ['$.requirements[0].workflow: fewer than 1 items']);
  assert.deepEqual(one((r) => (r.fix = 'Add it.')), ['$.requirements[0].fix: shorter than 21']);
  assert.deepEqual(one((r) => (r.colour = 'red')), ['$.requirements[0]: unknown property colour']);
  assert.deepEqual(one((r) => (r.id = 'Pinned Tool')), ['$.requirements[0].id: does not match ^[a-z-]+\\.[a-z0-9-]+$']);
  const lane = CONTRACT.requirements.findIndex((r) => r.kind === 'lane-environment');
  assert.deepEqual(problemsOf(mutated((c) => delete c.requirements[lane].prefix)), [`$.requirements[${lane}]: has no prefix`]);
});

test('the profiles are all there, each by its workflow files', () => {
  assert.deepEqual(problemsOf(mutated((c) => delete c.profiles.security)), ['$.profiles: has no security']);
  assert.deepEqual(problemsOf(mutated((c) => (c.profiles.nightly = { workflows: [] }))), [
    `$.profiles key nightly: "nightly" is not one of ${SCHEMA.$defs.profileName.enum.join(', ')}`,
  ]);
  assert.deepEqual(problemsOf(mutated((c) => delete c.profiles.web.workflows)), ['$.profiles.web: has no workflows']);
  assert.deepEqual(problemsOf(mutated((c) => (c.profiles.web.workflows = 'build-web.yml'))), ['$.profiles.web.workflows: is string, not array']);
  assert.deepEqual(problemsOf(mutated((c) => (c.profiles.web.makeCi = false))), ['$.profiles.web.makeCi: must be true']);
  assert.deepEqual(problemsOf(mutated((c) => (c.profiles.web.title = ''))), ['$.profiles.web.title: shorter than 1']);
  assert.deepEqual(problemsOf(mutated((c) => (c.profiles = {}))).length, 8);
  assert.deepEqual(problemsOf({ profiles: CONTRACT.profiles, requirements: [] }), ['$.requirements: fewer than 1 items']);
  assert.deepEqual(problemsOf({ requirements: CONTRACT.requirements }), ['$: has no profiles']);
  assert.deepEqual(problemsOf({ ...CONTRACT, '$schema-notes': { kind: 1 } }), ['$.$schema-notes.kind: is number, not string']);
});

test('the validator checks minProperties, which the contract schema leaves to required', () => {
  assert.deepEqual(validate({}, { type: 'object', minProperties: 1 }), ['$: fewer than 1 properties']);
  assert.deepEqual(validate({ a: 1 }, { type: 'object', minProperties: 1 }), []);
});

test('every workflow a profile names is a workflow file of this repository, in one profile only', () => {
  const owner = new Map();
  for (const [profile, { workflows }] of Object.entries(CONTRACT.profiles)) {
    for (const name of workflows) {
      assert.ok(existsSync(new URL(`../../.github/workflows/${name}`, import.meta.url)), `${profile}: .github/workflows/${name} does not exist`);
      assert.ok(!owner.has(name), `${name} is in both ${owner.get(name)} and ${profile}`);
      owner.set(name, profile);
    }
  }
  assert.ok(owner.size >= 15, `only ${owner.size} workflows mapped`);
});

test("a requirement's own workflow and toggle are workflows of its profile, and its id starts with its kind", () => {
  for (const r of CONTRACT.requirements) {
    const workflows = CONTRACT.profiles[r.profile].workflows;
    for (const name of r.workflow ?? []) assert.ok(workflows.includes(name), `${r.id}: ${name} is not a ${r.profile} workflow`);
    if (r.toggle) assert.ok(workflows.includes(r.toggle.split(':')[0]), `${r.id}: ${r.toggle} is not a ${r.profile} workflow's input`);
    assert.ok(r.id.startsWith(`${r.kind}.`), `${r.id}: does not start with ${r.kind}.`);
  }
});

test('the profiles a repository with no caller is held to, and the make ci profiles, are checks and unit', () => {
  const flagged = (flag) => Object.keys(CONTRACT.profiles).filter((name) => CONTRACT.profiles[name][flag]);
  assert.deepEqual(flagged('withoutCaller'), ['checks', 'unit']);
  assert.deepEqual(flagged('makeCi'), ['checks', 'unit']);
});

test('$schema-notes explains every profile field the schema allows', () => {
  for (const field of Object.keys(SCHEMA.$defs.profile.properties).filter((name) => name !== '$comment')) {
    assert.ok(CONTRACT['$schema-notes'][`profiles.${field}`], `no $schema-notes entry for profiles.${field}`);
  }
});
