// Evaluates the job graph of a workflow the way GitHub decides it, for the
// pipelines' tests: each job's `if:` against { inputs, needs, cancelled }, with
// the implicit success() a job without a status function gets from `needs`,
// and `skipped` handed on to the jobs after it.
//
// Only the terms the pipelines use are translated. Anything else is left as
// text and then rejected, so a new term fails the test that meets it instead of
// evaluating wrongly. `&&`, `||` and `!` need no translation: on booleans and
// strings GitHub's behave like JavaScript's, and an input that was never passed
// is `undefined` here and '' there - unequal to the same strings in both.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';

/** A workflow file as an object. yq is already a dependency of every test here. */
export function loadWorkflow(file) {
  return JSON.parse(execFileSync('yq', ['-o=json', '.', file], { encoding: 'utf8' }));
}

/** An `if:` without its `${{ }}`, which GitHub allows either way. */
export function unwrap(expression) {
  return /^\$\{\{\s*([\s\S]*?)\s*\}\}$/.exec(String(expression))?.[1] ?? String(expression);
}

/** An expression as JavaScript over { inputs, needs, cancelled, failure }. */
export function translate(expression) {
  const js = expression
    .replace(/contains\(fromJSON\('(\[[^']*\])'\), (inputs\.[\w-]+)\)/g, '$1.includes($2)')
    .replace(/\bcancelled\(\)/g, 'cancelled')
    .replace(/\bfailure\(\)/g, 'failure')
    .replace(/\balways\(\)/g, 'true')
    .replace(/\binputs\.([\w-]+)/g, (_, name) => `inputs[${JSON.stringify(name)}]`)
    .replace(/\bneeds\.([\w-]+)\.result/g, (_, job) => `needs[${JSON.stringify(job)}].result`)
    .replace(/([!=])=/g, '$1==');
  const rest = js.replace(
    /needs\["[\w-]+"\]\.result|inputs\["[\w-]+"\]|\[(?:'[^']*'(?:, )?|"[^"]*"(?:, )?)+\]\.includes|\bcancelled\b|\bfailure\b|\btrue\b|\bfalse\b|'[^']*'|[()!=&|\s]/g,
    '',
  );
  assert.equal(rest, '', `the gate uses a term this test cannot evaluate: ${expression}`);
  return js;
}

/** A job's `if:` as a function of { inputs, needs, cancelled, failure }. */
export function compile(expression) {
  const gate = new Function('{ inputs, needs, cancelled, failure }', `return ${translate(expression)};`);
  // No status function means GitHub prepends success(): the run is not
  // cancelled and every job it needs succeeded. A skipped one is not a success.
  if (/\b(?:success|failure|cancelled|always)\(\)/.test(expression)) return gate;
  return (context) => !context.cancelled && Object.values(context.needs).every((job) => job.result === 'success') && gate(context);
}

/**
 * Every job's result for one run of a workflow, in `needs` order.
 *
 * `outcome` names the result a job that runs ends with (default success),
 * `inputs` are the workflow_call inputs (a default the caller did not pass is
 * filled in from the workflow's own declaration), `cancelled` is a cancelled
 * run. A `uses:` job's `if:` is read from the workflow, so the test evaluates
 * the file as written.
 */
export function run(workflow, { inputs = {}, outcome = {}, cancelled = false } = {}) {
  const declared = workflow.on.workflow_call.inputs ?? {};
  const given = { ...Object.fromEntries(Object.entries(declared).map(([name, spec]) => [name, spec.default])), ...inputs };
  const results = {};
  const failed = {};
  const pending = Object.keys(workflow.jobs);
  const needsOf = (name) => [workflow.jobs[name].needs ?? []].flat();
  while (pending.length > 0) {
    const index = pending.findIndex((name) => needsOf(name).every((need) => need in results));
    assert.notEqual(index, -1, `a needs cycle, or a need that names no job: ${pending.join(', ')}`);
    const [name] = pending.splice(index, 1);
    const needs = Object.fromEntries(needsOf(name).map((need) => [need, { result: results[need] }]));
    // failure() looks at the whole chain behind a job, not only its direct needs.
    const failure = needsOf(name).some((need) => results[need] === 'failure' || failed[need]);
    const gate = compile(unwrap(workflow.jobs[name].if ?? 'true'));
    const runs = gate({ inputs: given, needs, cancelled, failure });
    results[name] = runs ? (outcome[name] ?? 'success') : 'skipped';
    failed[name] = failure;
  }
  return results;
}
