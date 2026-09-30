// A Makefile as make reads it: its own text with each `include` and
// `-include` line replaced by the text of the files it names, recursively. A
// shared `.mk` fragment is then seen by every program that reads targets
// (help, check-make-target-names, check-docs, the contract's Makefile
// reader) exactly as `make` sees it.
//
// Only files that exist are followed. `-include` says a missing file is fine,
// and a missing plain `include` already fails `make` itself with a better
// message than this could give; check-make-recipes is the program that reports
// one. A path built from a make variable (`$(DIR)/x.mk`) is left alone: it
// cannot be resolved without running make.
import path from 'node:path';

const INCLUDE = /^(?:-|s)?include\s+(.+)$/;

/** The plain paths an `include`, `-include` or `sinclude` line names, or null for any other line. */
export function includedPaths(line) {
  const match = INCLUDE.exec(line);
  if (!match) return null;
  return match[1]
    .replace(/\s#.*$/, '')
    .trim()
    .split(/\s+/)
    .filter((file) => !file.includes('$('));
}

/**
 * The text of the Makefile at `file` with every include expanded in place, or
 * null when `read(file)` is null. Includes resolve against `root`, the
 * directory make runs in, as make resolves them; each file is read once, so an
 * include cycle ends.
 */
export function expandIncludes(file, read, root = path.dirname(file), seen = new Set()) {
  const text = read(file);
  if (text === null) return null;
  seen.add(file);
  const lines = [];
  for (const line of text.split('\n')) {
    const includes = includedPaths(line);
    if (includes === null) {
      lines.push(line);
      continue;
    }
    for (const include of includes) {
      const nested = path.isAbsolute(include) ? include : path.join(root, include);
      if (seen.has(nested)) continue;
      const expanded = expandIncludes(nested, read, root, seen);
      if (expanded !== null) lines.push(expanded.replace(/\n$/, ''));
    }
  }
  return lines.join('\n');
}

/** The `##`-documented targets of a Makefile's text, as `[{ target, description }]`, in file order. */
export function documentedTargets(text) {
  return [...text.matchAll(/^([a-zA-Z0-9_.-]+):[^#\n=]*## ?(.*)$/gm)].map((match) => ({
    target: match[1],
    description: match[2].trim(),
  }));
}
