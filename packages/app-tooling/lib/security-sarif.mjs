#!/usr/bin/env node
// SARIF 2.1.0 documents for the security scanners. Two shapes matter:
//
//   skipped(tool, reason)  - nothing to scan. An empty run carrying a
//                            toolExecutionNotifications note and
//                            executionSuccessful: false, so a summary reads
//                            "skipped: reason" and never "clean".
//   fromFindings(tool, []) - a clean run. Empty results, but the invocation
//                            succeeded. The distinction is the whole point.
//
// A scanner that already speaks SARIF writes its own; this is for the ones
// that do not. Bash runners use the CLI:
//
//     node lib/security-sarif.mjs skip osv-scanner "not installed"
//     printf 'FAIL\tid\tfile:12\tmessage\n' | node lib/security-sarif.mjs lines checks
//
// A line's first field is ok or skip (not a finding), FAIL (high), warn
// (medium), or a severity outright: critical, high, medium or low.
import { readFileSync } from 'node:fs';
import { isProgram } from './is-program.mjs';

export const LEVEL_OF = { critical: 'error', high: 'error', medium: 'warning', low: 'note' };
// The GitHub code-scanning scale: 9+ critical, 7 high, 4 medium, below that low.
export const SECURITY_SEVERITY_OF = { critical: '9.0', high: '7.0', medium: '4.0', low: '1.0' };
// FAIL and warn are the verify scripts' own words; a runner that knows a
// finding's weight better than pass/fail says it outright with a severity.
const SEVERITY_OF_VERB = {
  FAIL: 'high',
  warn: 'medium',
  critical: 'critical',
  high: 'high',
  medium: 'medium',
  low: 'low',
};

const document = (run) => ({
  $schema: 'https://json.schemastore.org/sarif-2.1.0.json',
  version: '2.1.0',
  runs: [run],
});

const driver = (tool) => ({ driver: { name: tool } });

export const skipped = (tool, reason) =>
  document({
    tool: driver(tool),
    results: [],
    invocations: [
      {
        executionSuccessful: false,
        toolExecutionNotifications: [{ level: 'note', message: { text: `skipped: ${reason}` } }],
      },
    ],
  });

export const fromFindings = (tool, findings) =>
  document({
    tool: driver(tool),
    invocations: [{ executionSuccessful: true }],
    results: findings.map((finding) => {
      const level = LEVEL_OF[finding.severity];
      if (!level)
        throw new Error(
          `unknown severity ${JSON.stringify(finding.severity)} for ${finding.ruleId}`,
        );
      return {
        ruleId: finding.ruleId,
        level,
        message: { text: finding.message },
        properties: { 'security-severity': SECURITY_SEVERITY_OF[finding.severity] },
        locations: [
          {
            physicalLocation: {
              artifactLocation: { uri: finding.file },
              region: { startLine: finding.line },
            },
          },
        ],
      };
    }),
  });

/** A clean run that still has something to say, such as how much it looked at. */
export const noted = (tool, text) => {
  const doc = fromFindings(tool, []);
  doc.runs[0].invocations[0].toolExecutionNotifications = [{ level: 'note', message: { text } }];
  return doc;
};

/** The clean run for a CycloneDX bill; throws when the bill is not one, or lists nothing. */
export const fromBom = (tool, bom) => {
  if (bom?.bomFormat !== 'CycloneDX') throw new Error('not a CycloneDX document');
  const count = Array.isArray(bom.components) ? bom.components.length : 0;
  if (count === 0) throw new Error('the bill lists no components');
  return noted(tool, `${count} components in the bill of materials`);
};

/** One `verb<TAB>rule<TAB>file[:line]<TAB>message` line, or null when it is not a finding. */
export const parseLine = (line) => {
  if (!line.trim()) return null;
  const [verb, ruleId, where = '', ...rest] = line.split('\t');
  if (verb === 'ok' || verb === 'skip') return null;
  const severity = Object.hasOwn(SEVERITY_OF_VERB, verb) ? SEVERITY_OF_VERB[verb] : undefined;
  if (!severity) throw new Error(`unknown verb ${JSON.stringify(verb)} in: ${line}`);
  const match = /^(.*):(\d+)$/.exec(where);
  return {
    ruleId,
    file: match ? match[1] : where,
    line: match ? Number(match[2]) : 1,
    severity,
    message: rest.join('\t'),
  };
};

/** Command-line entry; returns the exit code. */
export function main(
  argv = process.argv.slice(2),
  { log = console.log, error = console.error, stdin = 0 } = {},
) {
  const [command, tool, ...rest] = argv;
  if (command === 'skip' && tool && rest.length) {
    log(JSON.stringify(skipped(tool, rest.join(' ')), null, 2));
    return 0;
  }
  if (command === 'bom' && tool && rest.length === 1) {
    try {
      log(JSON.stringify(fromBom(tool, JSON.parse(readFileSync(rest[0], 'utf8'))), null, 2));
      return 0;
    } catch (cause) {
      error(`${rest[0]}: ${cause.message}`);
      return 1;
    }
  }
  if (command === 'lines' && tool) {
    const findings = readFileSync(stdin, 'utf8').split('\n').map(parseLine).filter(Boolean);
    log(JSON.stringify(fromFindings(tool, findings), null, 2));
    return 0;
  }
  error(
    'usage: security-sarif.mjs skip <tool> <reason> | lines <tool> < findings | bom <tool> <file>',
  );
  return 2;
}

if (isProgram(import.meta.url, process.argv[1])) process.exitCode = main();
