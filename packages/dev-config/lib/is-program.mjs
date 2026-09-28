// Whether a module was run as a program rather than imported, for the bins that
// cannot rely on `import.meta.main` (it needs a newer node than this package's
// engines floor).
//
// `realpathSync`, not `path.resolve` alone: node resolves symlinks when it loads
// a module, so `import.meta.url` is the real path while `process.argv[1]` is
// what the caller typed. A package manager installs a `bin` entry into
// node_modules/.bin as a link, so without it the advertised `pnpm exec <bin>`
// would read as "imported": no output, exit 0, a gate that silently passed.
import { realpathSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

/**
 * Whether the module at `moduleUrl` is the program node was started with, given
 * the script path it was started with (`process.argv[1]`).
 */
export function isProgram(moduleUrl, scriptPath) {
  if (!scriptPath) return false;
  try {
    return fileURLToPath(moduleUrl) === realpathSync(path.resolve(scriptPath));
  } catch {
    return false;
  }
}
