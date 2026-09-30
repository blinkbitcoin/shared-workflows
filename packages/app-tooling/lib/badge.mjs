// Pure badge logic: thresholds, the GitHub-result map and the SVG renderer.
// The programs in bin/ (gen-badges, gen-coverage-badge, gen-status-badge) and
// lib/security-badge.mjs wrap it with file reads/writes, environment reads and
// exit codes, so the arithmetic and the markup are unit tested without touching
// the filesystem (`badge.test.mjs`).
//
// Why the SVG is rendered here instead of depending on `badge-maker`: the
// format is small, fully specified by the output we need (a shields.io "flat"
// badge), and this package has no dependencies on purpose - a rendering
// dependency buys a few dozen lines of markup at the cost of a package on the
// critical path of every consumer's CI run. The one genuinely hard part of a
// flat badge is measuring the text, and `textLength` pins the glyph run to the
// width we computed, so an imperfect estimate shifts letter spacing by a
// fraction of a pixel instead of overflowing the coloured box.

export class BadgeError extends Error {}

/** Where the coverage number is read from, relative to the consumer root. */
export const SUMMARY_PATH = 'coverage/coverage-summary.json';
/** Where every badge is written, relative to the consumer root. */
export const BADGE_DIR = 'coverage/badge';

/** shields.io's named colours, the only ones this repo's badges use. */
export const COLORS = {
  brightgreen: '#4c1',
  green: '#97ca00',
  yellowgreen: '#a4a61d',
  yellow: '#dfb317',
  orange: '#fe7d37',
  red: '#e05d44',
  lightgrey: '#9f9f9f',
  blue: '#007ec6',
};

/** Coverage placeholders CI renders when there is no measured number. */
export const PLACEHOLDERS = { failing: 'red', pending: 'yellow' };

// GitHub job results -> badge text/colour. Anything else (a typo, a future
// result value) is an error rather than a silently green badge.
export const STATUS_RESULTS = {
  success: { message: 'passing', color: 'brightgreen' },
  failure: { message: 'failing', color: 'red' },
  cancelled: { message: 'cancelled', color: 'lightgrey' },
  skipped: { message: 'skipped', color: 'lightgrey' },
};

// The security verdict's words (check-security.yml's `verdict` output) -> badge
// text/colour, plus `disabled`, which a caller sends when it has switched the
// gate off. `informational` takes its message from the highest
// severity instead. Anything else throws, like STATUS_RESULTS.
export const SECURITY_VERDICTS = {
  pass: { message: 'passing', color: 'brightgreen' },
  informational: { message: null, color: 'yellow' },
  skipped: { message: 'skipped', color: 'lightgrey' },
  fail: { message: 'failing', color: 'red' },
  disabled: { message: 'disabled', color: 'lightgrey' },
};

const FINDING_SEVERITIES = ['low', 'medium', 'high', 'critical'];

/** check-security.yml's verdict output (one line of JSON) -> the badge. */
export function securityBadgeFor(raw, label = 'Security') {
  let value;
  try {
    value = JSON.parse(raw);
  } catch {
    throw new BadgeError(`security badge: the verdict is not JSON: ${raw}`);
  }
  const known = SECURITY_VERDICTS[value?.verdict];
  if (!known) {
    throw new BadgeError(
      `security badge: unknown verdict in ${raw} — expected one of ${Object.keys(SECURITY_VERDICTS).join(', ')}`,
    );
  }
  let { message, color } = known;
  if (value.verdict === 'informational') {
    if (!FINDING_SEVERITIES.includes(value.highest)) {
      throw new BadgeError(`security badge: informational needs a finding severity, got ${raw}`);
    }
    message = `${value.highest} findings`;
    if (value.highest === 'high' || value.highest === 'critical') color = 'orange';
  }
  // Only a result that reads as fine gets the note: a skipped run already
  // says it checked nothing, and `fail` cannot happen when nothing can block.
  if (value.canBlock === false && (value.verdict === 'pass' || value.verdict === 'informational')) {
    message += ' (advisory)';
  }
  return { label, message, color };
}

export function colorFor(pct) {
  if (pct >= 100) return 'brightgreen';
  if (pct >= 90) return 'green';
  if (pct >= 80) return 'yellowgreen';
  if (pct >= 70) return 'yellow';
  return 'red';
}

export function formatPercent(pct) {
  const fixed = pct.toFixed(1);
  return `${fixed.endsWith('.0') ? fixed.slice(0, -2) : fixed}%`;
}

/**
 * argv -> the requested placeholder status, or null when `--status` is absent.
 * Throws BadgeError on an unrecognised value; the CLI prints it and exits 1.
 */
export function parseStatus(argv) {
  const i = argv.indexOf('--status');
  if (i === -1) return null;
  const status = argv[i + 1];
  if (!(status in PLACEHOLDERS)) {
    throw new BadgeError(
      `gen-coverage-badge: --status must be one of ${Object.keys(PLACEHOLDERS).join(', ')}`,
    );
  }
  return status;
}

/**
 * The coverage number a `coverage-summary.json` reports, as `{ message, color,
 * detail }`. Line coverage, because that is what the README badge has always
 * claimed to show and what `jest.config.ts` enforces first.
 */
export function coverageFrom(summary) {
  const lines = summary?.total?.lines;
  if (!lines || typeof lines.covered !== 'number' || typeof lines.total !== 'number') {
    throw new BadgeError(
      'gen-coverage-badge: coverage-summary.json has no total.lines — is `json-summary` still in jest.config.ts coverageReporters?',
    );
  }
  if (lines.total === 0) {
    throw new BadgeError('gen-coverage-badge: no lines measured at all — refusing to render');
  }
  const pct = (lines.covered / lines.total) * 100;
  return {
    message: formatPercent(pct),
    color: colorFor(pct),
    detail: `${lines.covered}/${lines.total} lines`,
  };
}

// Advance widths of 11px Verdana, the face shields.io measures against, in
// pixels. Only printable ASCII is listed; anything else falls back to
// DEFAULT_WIDTH.
//
// What keeps an unlisted glyph inside its box is `textLength`, not this table:
// renderBadgeSvg pins each glyph run to exactly the width it computed, so a
// wrong estimate changes letter spacing and never the geometry. The table only
// decides how much room the text is *given*. DEFAULT_WIDTH is therefore set
// near the wide end of the table (`W` is 11.3, `@` 12.4) rather than at the
// average: a non-ASCII label - and `unit-label`/`e2e-label` are consumer
// inputs - then errs toward padding instead of squashed glyphs. CJK is wider
// still and will squash a little; that is the honest limit of measuring text
// without the font.
const DEFAULT_WIDTH = 11;
// One row per character class, so it reads as the table it is.
const CHAR_WIDTHS = {
  ' ': 3.93, '!': 4.58, '"': 5.6, '#': 9.2, $: 6.9, '%': 11.4, '&': 8, "'": 3.2,
  '(': 4.6, ')': 4.6, '*': 6.9, '+': 9.2, ',': 3.9, '-': 4.6, '.': 3.9, '/': 4.6,
  0: 6.9, 1: 6.9, 2: 6.9, 3: 6.9, 4: 6.9, 5: 6.9, 6: 6.9, 7: 6.9, 8: 6.9, 9: 6.9,
  ':': 4.6, ';': 4.6, '<': 9.2, '=': 9.2, '>': 9.2, '?': 5.9, '@': 12.4,
  A: 7.6, B: 7.5, C: 7.5, D: 8.2, E: 6.9, F: 6.4, G: 8.4, H: 8.2, I: 3.9, J: 4.6,
  K: 7.5, L: 6, M: 9.4, N: 8, O: 8.7, P: 6.7, Q: 8.7, R: 7.7, S: 7.2, T: 6.8,
  U: 8, V: 7.6, W: 11.3, X: 7.5, Y: 6.8, Z: 7,
  '[': 4.6, '\\': 4.6, ']': 4.6, '^': 9.2, _: 6.9, '`': 6.9,
  a: 6.5, b: 6.9, c: 5.6, d: 6.9, e: 6.6, f: 4, g: 6.9, h: 6.7, i: 3, j: 3.6,
  k: 6.2, l: 3, m: 10.2, n: 6.7, o: 6.6, p: 6.9, q: 6.9, r: 4.6, s: 5.6, t: 4.3,
  u: 6.7, v: 6.2, w: 8.9, x: 6.1, y: 6.2, z: 5.6,
  '{': 6.9, '|': 4.6, '}': 6.9, '~': 9.2,
};

/** Rendered width of `text` in 11px Verdana, rounded up to whole pixels. */
export function textWidth(text) {
  let total = 0;
  for (const ch of String(text)) total += CHAR_WIDTHS[ch] ?? DEFAULT_WIDTH;
  return Math.ceil(total);
}

export function escapeXml(value) {
  return String(value).replace(
    /[&<>"']/g,
    (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&apos;' })[c],
  );
}

/**
 * One shields.io-shaped "flat" badge. `color` is a name from COLORS; an unknown
 * one is a BadgeError rather than a badge with no fill at all.
 */
export function renderBadgeSvg({ label, message, color }) {
  const fill = COLORS[color];
  if (!fill) {
    throw new BadgeError(
      `badge: unknown colour "${color}" — expected one of ${Object.keys(COLORS).join(', ')}`,
    );
  }
  // 5px of padding either side of each half, the shields.io flat geometry.
  const labelText = textWidth(label);
  const messageText = textWidth(message);
  const labelBox = labelText + 10;
  const messageBox = messageText + 10;
  const width = labelBox + messageBox;
  // Text is drawn at font-size 110 and scaled by 0.1, so a tenth of a pixel is
  // expressible; every x/y below is therefore ten times its real value.
  const labelX = labelBox * 5;
  const messageX = (labelBox + messageBox / 2) * 10;
  const alt = `${escapeXml(label)}: ${escapeXml(message)}`;
  const text = (x, len, body) =>
    `<text aria-hidden="true" x="${x}" y="150" fill="#010101" fill-opacity=".3" transform="scale(.1)" textLength="${len}">${body}</text>` +
    `<text x="${x}" y="140" transform="scale(.1)" textLength="${len}">${body}</text>`;
  // viewBox as well as width/height: shields.io omits it, but without one a
  // consumer who gives the <img> a CSS width gets a stretched viewport around
  // fixed-size content instead of a scaled badge.
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="20" viewBox="0 0 ${width} 20" role="img" aria-label="${alt}">
<title>${alt}</title>
<linearGradient id="s" x2="0" y2="100%"><stop offset="0" stop-color="#bbb" stop-opacity=".1"/><stop offset="1" stop-opacity=".1"/></linearGradient>
<clipPath id="r"><rect width="${width}" height="20" rx="3" fill="#fff"/></clipPath>
<g clip-path="url(#r)">
<rect width="${labelBox}" height="20" fill="#555"/>
<rect x="${labelBox}" width="${messageBox}" height="20" fill="${fill}"/>
<rect width="${width}" height="20" fill="url(#s)"/>
</g>
<g fill="#fff" text-anchor="middle" font-family="Verdana,Geneva,DejaVu Sans,sans-serif" text-rendering="geometricPrecision" font-size="110">
${text(labelX, labelText * 10, escapeXml(label))}
${text(messageX, messageText * 10, escapeXml(message))}
</g>
</svg>
`;
}

/** The shields.io endpoint JSON for the same badge, written next to the SVG. */
export function renderBadgeJson({ label, message, color }) {
  return `${JSON.stringify({ schemaVersion: 1, label, message, color }, null, 2)}\n`;
}
