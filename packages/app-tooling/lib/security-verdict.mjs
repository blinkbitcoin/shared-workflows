#!/usr/bin/env node
// Merges the scanners' SARIF files into one verdict.
//
//     node lib/security-verdict.mjs .security
//
// Exits 1 when a finding at or above the configured severity comes from a job
// whose engine class is listed in failOn. Every other case exits 0: a finding
// never fails its own scanner, and an engine outside failOn annotates only.
// The same file runs locally and in CI, so `check-security` gives the
// answer the pipeline will give.
import { readdirSync, readFileSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { load, SEVERITIES } from './security-settings.mjs';
import { isProgram } from './is-program.mjs';

/** Which engine class each job belongs to. failOn names classes, not jobs. */
export const ENGINE_OF = {
  dependencies: 'deterministic',
  code: 'deterministic',
  policy: 'deterministic',
  sbom: 'deterministic',
  bundle: 'deterministic',
  mobile: 'deterministic',
  binaries: 'deterministic',
  review: 'review',
  'review-codebase': 'openant',
};

export const ORDER = ['low', 'medium', 'high', 'critical'];

/** The only engine classes failOn may legitimately name - derived from ENGINE_OF, not a second list to drift. */
export const ENGINE_CLASSES = [...new Set(Object.values(ENGINE_OF))];

const FROM_LEVEL = { error: 'high', warning: 'medium', note: 'low' };

// SARIF puts a rule's numeric severity on tool.driver.rules[], not on the
// result - a scanner reports "this result fired ruleId X" and expects a
// reader to look X up. osv-scanner does exactly that: every result is
// `level: warning` regardless of score, and the CVSS number lives only on
// the matching rule. CodeQL uses the same convention, so a result's own
// properties are checked first (a scanner is free to repeat the score there)
// and the owning rule is the fallback, not a special case.
/** GitHub's numeric scale first (result, then its rule), the SARIF level last. */
export const severityOf = (result, rule) => {
  const score = Number(
    result.properties?.['security-severity'] ?? rule?.properties?.['security-severity'],
  );
  if (Number.isFinite(score)) {
    if (score >= 9) return 'critical';
    if (score >= 7) return 'high';
    if (score >= 4) return 'medium';
    return 'low';
  }
  return FROM_LEVEL[result.level] ?? 'medium';
};

const rulesOf = (run) =>
  Object.fromEntries((run.tool?.driver?.rules ?? []).map((rule) => [rule.id, rule]));

const resultsOf = (document) =>
  (document.runs ?? []).flatMap((run) => {
    const rules = rulesOf(run);
    return (run.results ?? [])
      .filter((r) => !(r.suppressions ?? []).length)
      .map((result) => ({ result, rule: rules[result.ruleId] }));
  });

// A suppressed result (osv-scanner.toml, .semgrepignore, an inline marker)
// is deliberately dropped from `resultsOf` above - it must never count
// toward severity or block a run. But dropping it with no trace anywhere
// makes a suppression indistinguishable from a result that was never found
// at all, which is not the same claim. Counted separately so the summary can
// say "N suppressed" instead of going silent about them.
const suppressedCountOf = (document) =>
  (document.runs ?? []).reduce(
    (total, run) =>
      total + (run.results ?? []).filter((r) => (r.suppressions ?? []).length > 0).length,
    0,
  );

const ranOf = (document) =>
  (document.runs ?? []).every((run) =>
    (run.invocations ?? []).every((i) => i.executionSuccessful !== false),
  );

/** Counts, the highest severity seen, which jobs skipped, every finding, and how many were suppressed. */
export const summarize = (entries) => {
  const counts = { critical: 0, high: 0, medium: 0, low: 0 };
  const skipped = [];
  const findings = [];
  let suppressed = 0;
  for (const { job, document } of entries) {
    if (!ranOf(document)) skipped.push(job);
    suppressed += suppressedCountOf(document);
    for (const { result, rule } of resultsOf(document)) {
      const severity = severityOf(result, rule);
      const where = result.locations?.[0]?.physicalLocation;
      counts[severity] += 1;
      findings.push({
        job,
        severity,
        ruleId: result.ruleId ?? '<no rule>',
        message: result.message?.text ?? '',
        file: where?.artifactLocation?.uri,
        line: where?.region?.startLine,
      });
    }
  }
  const highest = [...ORDER].reverse().find((s) => counts[s] > 0) ?? 'none';
  return { counts, highest, skipped, findings, suppressed };
};

// Workflow command escaping: the data half loses only %, CR and LF; a property
// value also loses : and , because those separate the properties.
const escapeData = (text) =>
  String(text).replaceAll('%', '%25').replaceAll('\r', '%0D').replaceAll('\n', '%0A');
const escapeProperty = (text) => escapeData(text).replaceAll(':', '%3A').replaceAll(',', '%2C');

/**
 * One `::error` or `::warning` workflow command for a finding, which the runner
 * shows on the pull request's diff. Code scanning no longer does that on a pull
 * request - check-security.yml uploads from the default branch only - so this
 * is where a finding meets the change that introduced it.
 */
export const annotation = (level, finding) => {
  const properties = [
    finding.file && `file=${escapeProperty(finding.file)}`,
    finding.file && finding.line && `line=${finding.line}`,
    `title=${escapeProperty(`Security ${finding.severity}: ${finding.ruleId}`)}`,
  ].filter(Boolean);
  return `::${level} ${properties.join(',')}::${escapeData(finding.message || finding.ruleId)}`;
};

/** The verdict, its exit code, the lines to print and the annotations for CI. */
export const verdict = ({ entries, severity, failOn }) => {
  // This is the only module allowed to fail a run, so it does not trust a
  // caller to have validated severity already: an unrecognized value throws
  // rather than silently behaving like 'none' (report, never block).
  if (!SEVERITIES.includes(severity)) {
    throw new Error(
      `severity: expected one of ${SEVERITIES.join(', ')}, got ${JSON.stringify(severity)}`,
    );
  }
  // Same reasoning as severity: `security-settings.mjs`'s parseList accepts any string,
  // so a dropped letter ("deterministc") or an unrelated word never reaches
  // ENGINE_CLASSES and `failOn.includes(...)` just quietly never matches -
  // every finding reads as informational and nothing can ever block, exactly
  // the fail-open this module exists to prevent for severity. An *empty*
  // failOn is different: it is a legitimate "everything is advisory" choice,
  // so it is allowed here and made visible in the summary line below instead.
  for (const entry of failOn) {
    if (!ENGINE_CLASSES.includes(entry)) {
      throw new Error(
        `failOn: unrecognized engine class ${JSON.stringify(entry)}, expected one of ${ENGINE_CLASSES.join(', ')}`,
      );
    }
  }
  // A job name with no entry in ENGINE_OF makes `failOn.includes(ENGINE_OF[job])`
  // evaluate to `failOn.includes(undefined)`, which is always false - a finding
  // from an unrecognized job could never block, however severe, and the summary
  // would still print it as merely "informational". Fail loudly instead, naming
  // the file, the same treatment given an unrecognized severity above.
  for (const { job } of entries) {
    if (!(job in ENGINE_OF)) {
      throw new Error(
        `${job}.sarif: unrecognized job "${job}" has no entry in ENGINE_OF, so it could never be blocked - add it there`,
      );
    }
  }
  const { counts, highest, skipped, findings, suppressed } = summarize(entries);
  const floor = ORDER.indexOf(severity);
  // 'none' (floor < 0) reports everything as informational but never blocks;
  // any other severity drops findings below the floor from both buckets, so
  // a below-threshold finding reads as clean rather than informational.
  const reportable = findings.filter((f) => floor < 0 || ORDER.indexOf(f.severity) >= floor);
  const blocking = floor >= 0 ? reportable.filter((f) => failOn.includes(ENGINE_OF[f.job])) : [];
  const lines = entries.map(({ job, document }) => {
    if (skipped.includes(job)) {
      const note = (document.runs ?? [])
        .flatMap((run) =>
          (run.invocations ?? []).flatMap((i) => i.toolExecutionNotifications ?? []),
        )
        .map((n) => n.message?.text)
        .filter(Boolean)[0];
      return `${job}: ${note ?? 'skipped: no reason given'}`;
    }
    const mine = findings.filter((f) => f.job === job);
    if (mine.length === 0) return `${job}: clean`;
    const worst = [...ORDER].reverse().find((s) => mine.some((f) => f.severity === s));
    return `${job}: ${mine.length} finding(s), highest ${worst}`;
  });
  for (const finding of findings) {
    lines.push(`  ${finding.severity}\t${finding.job}\t${finding.ruleId}\t${finding.message}`);
  }
  // A run with nothing reportable is only a "pass" when every job actually
  // ran. If at least one job skipped (missing tool, disabled job, no key),
  // the gate did not clear anything - "pass" is the word people and agents
  // grep for, and a laptop missing osv-scanner and semgrep must not get it.
  // The exit code stays 0 either way: nothing ran, so nothing blocks.
  const name =
    blocking.length > 0
      ? 'fail'
      : reportable.length > 0
        ? 'informational'
        : skipped.length > 0
          ? 'skipped'
          : 'pass';
  // An empty failOn is a legitimate "everything is advisory" choice, but it
  // must never look like an ordinary pass: nothing in this run could have
  // blocked, whatever it found, and that fact belongs on the one line most
  // likely to be the only one read.
  const failOnNote = failOn.length === 0 ? ', failOn is empty: nothing can block' : '';
  lines.push(
    `security: ${name}, highest ${highest}, ${findings.length} finding(s), ${suppressed} suppressed, ${skipped.length} job(s) skipped${failOnNote}`,
  );
  // Whether anything in this run could have failed it. The badge says
  // "(advisory)" when not, so a clean advisory run never reads as a pass that
  // was checked against a threshold.
  const canBlock = floor >= 0 && failOn.length > 0;
  return {
    verdict: name,
    highest,
    counts,
    suppressed,
    canBlock,
    lines,
    // A finding that blocks is an error; one that is only reported is a
    // warning. Below the severity floor it is neither, as in the lines above.
    annotations: reportable.map((finding) =>
      annotation(blocking.includes(finding) ? 'error' : 'warning', finding),
    ),
    exitCode: blocking.length > 0 ? 1 : 0,
  };
};

/** The file the badge reads, next to the SARIF it summarises. */
export const VERDICT_FILE = 'verdict.json';

// One line: shared-workflows' verdict-output.sh copies it into a step output
// as it is, and a step output is one line.
const writeVerdictFile = (dir, outcome) =>
  writeFileSync(
    path.join(dir, VERDICT_FILE),
    `${JSON.stringify({ verdict: outcome.verdict, highest: outcome.highest, canBlock: outcome.canBlock })}\n`,
  );

// readdirSync failing (dir does not exist, or is not a directory) and
// JSON.parse failing on one particular file are different problems with
// different fixes - "run a scanner first" sends someone chasing the wrong
// thing when the real issue is one bad file sitting next to good ones. The
// thrown error is tagged so main() can tell them apart without inspecting a
// filesystem error code that a mocked readEntries would not have anyway.
const read = (dir) =>
  readdirSync(dir)
    .filter((name) => name.endsWith('.sarif'))
    .sort()
    .map((name) => {
      const file = path.join(dir, name);
      // Kept as two separate steps, each with its own tagged error: a file
      // that cannot be read (permissions, a symlink to nowhere) and a file
      // that reads fine but is not valid JSON are different problems with
      // different fixes, and reporting a permission error as "not valid
      // JSON" would send someone straight past the actual cause.
      let raw;
      try {
        raw = readFileSync(file, 'utf8');
      } catch (cause) {
        const wrapped = new Error(`${file}: could not be read (${cause.message})`);
        wrapped.sarifReadError = true;
        throw wrapped;
      }
      let document;
      try {
        document = JSON.parse(raw);
      } catch (cause) {
        const wrapped = new Error(`${file}: not valid JSON (${cause.message})`);
        wrapped.sarifParseError = true;
        throw wrapped;
      }
      return { job: path.basename(name, '.sarif'), document };
    });

/** Command-line entry; returns the exit code. */
export function main(
  argv = process.argv.slice(2),
  {
    log = console.log,
    error = console.error,
    env = process.env,
    readEntries = read,
    writeVerdict = writeVerdictFile,
  } = {},
) {
  const dir = argv[0] ?? '.security';
  let entries;
  try {
    entries = readEntries(dir);
  } catch (err) {
    if (err.sarifParseError || err.sarifReadError) {
      error(err.message);
    } else {
      error(`no SARIF files in ${dir}: run a scanner first`);
    }
    return 2;
  }
  const settings = load('security-settings.json', env);
  const outcome = verdict({ entries, severity: settings.severity, failOn: settings.failOn });
  for (const line of outcome.lines) log(line);
  // Only on a runner: on a laptop, `check-security` would print them as
  // noise. verdict.sh in shared-workflows keeps them out of the run summary.
  if (env.GITHUB_ACTIONS === 'true') for (const line of outcome.annotations) log(line);
  // A verdict nobody can read is not a pass: CI would publish nothing, or a
  // stale badge. Exit 2, the same code as a SARIF file that cannot be read.
  try {
    writeVerdict(dir, outcome);
  } catch (err) {
    error(`${path.join(dir, VERDICT_FILE)}: could not be written (${err.message})`);
    return 2;
  }
  return outcome.exitCode;
}

if (isProgram(import.meta.url, process.argv[1])) process.exitCode = main();
