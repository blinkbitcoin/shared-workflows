// The files under a directory that a path pattern names. A pattern is
// slash-separated; a segment is a literal name, `*` (any one name, or any run
// of characters inside a name: `*.plist`) or `**` (any number of directories,
// including none). That is the whole language, because it is the whole of what
// a config assertion needs: `ios/*/Info.plist`, `ios/**/Splash.colorset`.
import { readdirSync, statSync } from 'node:fs';
import path from 'node:path';

/** A single segment as an anchored regular expression: `*` is any run of characters but `/`. */
export function segmentPattern(segment) {
  return new RegExp(`^${segment.split('*').map((part) => part.replace(/[.+?^${}()|[\]\\]/g, '\\$&')).join('[^/]*')}$`);
}

/**
 * The relative paths under `root` that match `pattern`, sorted, files and
 * directories alike. A pattern that names nothing, or a root that is not there,
 * gives an empty list.
 */
export function globFiles(root, pattern) {
  const segments = pattern.split('/').filter((segment) => segment !== '');
  const found = new Set();
  const entries = (directory) => {
    try {
      return readdirSync(path.join(root, directory));
    } catch {
      return [];
    }
  };
  const isDirectory = (relative) => {
    try {
      return statSync(path.join(root, relative)).isDirectory();
    } catch {
      return false;
    }
  };
  const walk = (directory, rest) => {
    if (rest.length === 0) {
      found.add(directory);
      return;
    }
    const [segment, ...tail] = rest;
    if (segment === '**') {
      walk(directory, tail);
      for (const name of entries(directory)) {
        const child = path.posix.join(directory, name);
        if (isDirectory(child)) walk(child, rest);
      }
      return;
    }
    const matches = segmentPattern(segment);
    for (const name of entries(directory)) {
      if (matches.test(name)) walk(path.posix.join(directory, name), tail);
    }
  };
  walk('', segments);
  found.delete('');
  return [...found].sort();
}
