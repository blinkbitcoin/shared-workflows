// A port written into a file that `APP_PORT_BASE` is supposed to move. The
// scan is a regular expression over lines, so it keys on how a number is used
// rather than on the number: `localhost:8081` and `port: 4000` are ports,
// `limit: 4000` is not.
import { closeSync, openSync, readSync } from 'node:fs';

/**
 * The expression matching a line that uses one of `literals` as a port. A number
 * only counts when it has one of these prefixes:
 *
 *   `:`                       a colon straight against the digits - `localhost:8081`, `tcp:8081`
 *   `%3A`                     the same colon percent-encoded, in a deep link
 *   `on` + slack              prose ("on 4000")
 *   `-p `                     the short CLI flag
 *   a port token + slack      `port 4000`, `port: 8082`, `${METRO_PORT:-8081}`,
 *                             `MOCK_API_PORT ?? 4000`, `PORT=8082`, `metroPort = 8081`
 *
 * "slack" is up to six non-digit characters, which reaches across `:-`, ` ?? `,
 * `=`, `: ` and ` = `. The token has three spellings on purpose: `\bport` for prose
 * and lowercase keys, `Port` for camelCase like `metroPort` (there is no word
 * boundary inside a camelCase word), and `PORT` for env-var case. A bare
 * case-insensitive `port` would also match the tail of "support".
 *
 * What is deliberately NOT a prefix: a colon followed by a space. `webPreview: 8083`
 * would be nice to catch, but `{ testflight: 4000 }` in a store notes generator is a
 * character limit and the same shape. Keying on a `port` token covers every real
 * consumer (a key that holds a port is called `port`) without allowlisting files
 * that have nothing to do with ports.
 */
export function portPattern(literals) {
  return new RegExp(
    `(?::|%3[Aa]|\\bon\\b[^0-9\\n]{0,6}|-p |(?:\\bport|Port|PORT)\\b[^0-9\\n]{0,6})(?:${literals.join('|')})(?![0-9])`,
  );
}

/**
 * A NUL in the first chunk is the cheap, extension-agnostic "this is not text"
 * test that git itself uses: a tracked asset read as UTF-8 yields replacement
 * characters, and a byte run that happens to decode to ":8081" would fail a
 * check with an unreadable message.
 */
export function isBinary(absolute) {
  const fd = openSync(absolute, 'r');
  try {
    const buffer = Buffer.alloc(8000);
    const read = readSync(fd, buffer, 0, buffer.length, 0);
    return buffer.subarray(0, read).includes(0);
  } finally {
    closeSync(fd);
  }
}

/** Whether `file` is `prefix` or lies under it (a prefix ending in `/` is a directory). */
export const isAllowed = (file, allow) => allow.some((prefix) => file === prefix || file.startsWith(prefix));
