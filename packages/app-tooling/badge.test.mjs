import assert from 'node:assert/strict';
import { describe, test } from 'node:test';
import {
  BADGE_DIR,
  BadgeError,
  COLORS,
  colorFor,
  coverageFrom,
  escapeXml,
  formatPercent,
  PLACEHOLDERS,
  parseStatus,
  renderBadgeJson,
  renderBadgeSvg,
  STATUS_RESULTS,
  SUMMARY_PATH,
  securityBadgeFor,
  textWidth,
} from './lib/badge.mjs';

const summaryWith = (covered, total) => ({
  total: { lines: { covered, total, skipped: 0, pct: (covered / total) * 100 } },
});

// publish-badges.yml's `badge-dir` default and check-unit.yml's coverage
// artifact layout both assume these two paths; moving one strands the other.
test('the default paths are the ones publish-badges.yml assumes', () => {
  assert.equal(BADGE_DIR, 'coverage/badge');
  assert.equal(SUMMARY_PATH, 'coverage/coverage-summary.json');
});

describe('colorFor', () => {
  test('walks the thresholds, boundaries included', () => {
    assert.equal(colorFor(100), 'brightgreen');
    assert.equal(colorFor(99.9), 'green');
    assert.equal(colorFor(90), 'green');
    assert.equal(colorFor(89.9), 'yellowgreen');
    assert.equal(colorFor(80), 'yellowgreen');
    assert.equal(colorFor(79.9), 'yellow');
    assert.equal(colorFor(70), 'yellow');
    assert.equal(colorFor(69.9), 'red');
    assert.equal(colorFor(0), 'red');
  });

  test('every colour it can return is a colour renderBadgeSvg knows', () => {
    for (const pct of [0, 70, 80, 90, 100]) assert.ok(COLORS[colorFor(pct)]);
  });
});

describe('formatPercent', () => {
  test('drops a trailing .0 but keeps a real decimal', () => {
    assert.equal(formatPercent(100), '100%');
    assert.equal(formatPercent(98.45), '98.5%');
    assert.equal(formatPercent(0), '0%');
    assert.equal(formatPercent(66.666), '66.7%');
  });
});

describe('STATUS_RESULTS', () => {
  test('covers every result GitHub can hand a dependent job', () => {
    assert.deepEqual(Object.keys(STATUS_RESULTS).sort(), [
      'cancelled',
      'failure',
      'skipped',
      'success',
    ]);
  });

  test('only success is green', () => {
    for (const [result, { color }] of Object.entries(STATUS_RESULTS)) {
      assert.equal(color === 'brightgreen', result === 'success');
      assert.ok(COLORS[color], `${result} uses an unknown colour`);
    }
  });
});

describe('parseStatus', () => {
  test('is null without --status', () => {
    assert.equal(parseStatus([]), null);
    assert.equal(parseStatus(['--out', 'x']), null);
  });

  test('accepts each placeholder', () => {
    for (const status of Object.keys(PLACEHOLDERS)) {
      assert.equal(parseStatus(['--status', status]), status);
    }
  });

  test('rejects anything else rather than rendering a green badge', () => {
    assert.throws(() => parseStatus(['--status', 'passing']), BadgeError);
    assert.throws(() => parseStatus(['--status']), BadgeError);
  });
});

describe('coverageFrom', () => {
  test('reports line coverage with its colour and detail', () => {
    assert.deepEqual(coverageFrom(summaryWith(348, 348)), {
      message: '100%',
      color: 'brightgreen',
      detail: '348/348 lines',
    });
    assert.deepEqual(coverageFrom(summaryWith(75, 100)), {
      message: '75%',
      color: 'yellow',
      detail: '75/100 lines',
    });
  });

  test('a summary with no total.lines is an error, not a 0% badge', () => {
    assert.throws(() => coverageFrom({}), BadgeError);
    assert.throws(() => coverageFrom({ total: {} }), BadgeError);
    assert.throws(() => coverageFrom({ total: { lines: { covered: 1 } } }), BadgeError);
  });

  test('zero measured lines refuses to render', () => {
    assert.throws(() => coverageFrom(summaryWith(0, 0)), BadgeError);
  });
});

describe('textWidth', () => {
  test('is zero for the empty string and grows with the text', () => {
    assert.equal(textWidth(''), 0);
    assert.ok(textWidth('Coverage') > textWidth('Unit'));
    assert.ok(textWidth('W') > textWidth('i'));
  });

  test('an unlisted glyph still gets a width', () => {
    assert.ok(textWidth('é') > 0);
  });
});

describe('escapeXml', () => {
  test('escapes every character that could close a tag or an attribute', () => {
    assert.equal(escapeXml(`<a href="x">&'`), '&lt;a href=&quot;x&quot;&gt;&amp;&apos;');
  });
});

describe('renderBadgeSvg', () => {
  const svg = renderBadgeSvg({ label: 'Coverage', message: '100%', color: 'brightgreen' });

  test('is a well-formed, self-contained flat badge', () => {
    assert.match(svg, /^<svg xmlns="http:\/\/www\.w3\.org\/2000\/svg"/);
    assert.match(svg, /<\/svg>\n$/);
    assert.ok(!svg.includes('<image'), 'a badge must not pull in an external resource');
    assert.equal(svg.split('<text').length - 1, 4, 'two halves, each with its shadow');
  });

  test('carries the colour and an accessible label', () => {
    assert.ok(svg.includes(`fill="${COLORS.brightgreen}"`));
    assert.ok(svg.includes('aria-label="Coverage: 100%"'));
    assert.ok(svg.includes('<title>Coverage: 100%</title>'));
  });

  test('the two boxes tile the full width exactly', () => {
    const width = Number(svg.match(/<svg[^>]*width="(\d+)"/)[1]);
    const label = Number(svg.match(/<rect width="(\d+)" height="20" fill="#555"\/>/)[1]);
    const message = Number(svg.match(/<rect x="\d+" width="(\d+)"/)[1]);
    assert.equal(label + message, width);
    assert.equal(Number(svg.match(/<rect x="(\d+)" width="\d+"/)[1]), label);
  });

  // The centring arithmetic is written asymmetrically (`labelBox * 5` against
  // `(labelBox + messageBox / 2) * 10`), which makes it the likeliest place for
  // a future typo - and a typo there is invisible to the tiling assertion
  // above. This pins both halves to their own box.
  test('each half is centred in its own box and pinned to that width', () => {
    const texts = [
      ...svg.matchAll(/<text x="(\d+)" y="140" transform="scale\(\.1\)" textLength="(\d+)"/g),
    ];
    assert.equal(texts.length, 2);
    // The two coloured halves, not the clipPath rect that spans the whole badge.
    const label = Number(svg.match(/<rect width="(\d+)" height="20" fill="#555"\/>/)[1]);
    const message = Number(svg.match(/<rect x="\d+" width="(\d+)" height="20" fill="#/)[1]);
    assert.equal(Number(texts[0][1]), (label * 10) / 2);
    assert.equal(Number(texts[0][2]), (label - 10) * 10);
    assert.equal(Number(texts[1][1]), (label + message / 2) * 10);
    assert.equal(Number(texts[1][2]), (message - 10) * 10);
  });

  // A badge with a CSS width should scale, not stretch its viewport.
  test('carries a viewBox matching its declared size', () => {
    const width = svg.match(/<svg[^>]*width="(\d+)"/)[1];
    assert.ok(svg.includes(`viewBox="0 0 ${width} 20"`));
  });

  test('a longer message makes a wider badge', () => {
    const short = renderBadgeSvg({ label: 'E2E', message: 'passing', color: 'brightgreen' });
    const long = renderBadgeSvg({ label: 'E2E', message: 'cancelled', color: 'lightgrey' });
    const width = (s) => Number(s.match(/<svg[^>]*width="(\d+)"/)[1]);
    assert.ok(width(long) > width(short));
  });

  test('markup in a label cannot escape into the SVG', () => {
    const evil = renderBadgeSvg({ label: '</text><script/>', message: 'x', color: 'red' });
    assert.ok(!evil.includes('<script'));
    assert.ok(evil.includes('&lt;/text&gt;'));
  });

  test('an unknown colour is an error, not an unfilled box', () => {
    assert.throws(
      () => renderBadgeSvg({ label: 'a', message: 'b', color: 'chartreuse' }),
      BadgeError,
    );
  });
});

describe('renderBadgeJson', () => {
  test('is the shields endpoint shape with a trailing newline', () => {
    const json = renderBadgeJson({ label: 'Unit', message: 'passing', color: 'brightgreen' });
    assert.match(json, /\n$/);
    assert.deepEqual(JSON.parse(json), {
      schemaVersion: 1,
      label: 'Unit',
      message: 'passing',
      color: 'brightgreen',
    });
  });
});

describe('securityBadgeFor', () => {
  const badge = (value) => securityBadgeFor(JSON.stringify(value));

  test('each verdict word has its own message and colour', () => {
    assert.deepEqual(badge({ verdict: 'pass', highest: 'none', canBlock: true }), {
      label: 'Security',
      message: 'passing',
      color: 'brightgreen',
    });
    assert.equal(badge({ verdict: 'fail', highest: 'high', canBlock: true }).color, 'red');
    assert.equal(badge({ verdict: 'fail', highest: 'high', canBlock: true }).message, 'failing');
    assert.equal(badge({ verdict: 'skipped', highest: 'none', canBlock: true }).message, 'skipped');
    assert.equal(badge({ verdict: 'disabled' }).message, 'disabled');
    assert.equal(badge({ verdict: 'disabled' }).color, 'lightgrey');
  });

  test('informational names its highest severity, orange from high up', () => {
    assert.deepEqual(badge({ verdict: 'informational', highest: 'medium', canBlock: true }), {
      label: 'Security',
      message: 'medium findings',
      color: 'yellow',
    });
    assert.equal(
      badge({ verdict: 'informational', highest: 'low', canBlock: true }).color,
      'yellow',
    );
    assert.equal(
      badge({ verdict: 'informational', highest: 'high', canBlock: true }).color,
      'orange',
    );
    assert.equal(
      badge({ verdict: 'informational', highest: 'critical', canBlock: true }).color,
      'orange',
    );
  });

  test('a run where nothing could block says so', () => {
    assert.equal(
      badge({ verdict: 'pass', highest: 'none', canBlock: false }).message,
      'passing (advisory)',
    );
    assert.equal(
      badge({ verdict: 'informational', highest: 'medium', canBlock: false }).message,
      'medium findings (advisory)',
    );
    assert.equal(
      badge({ verdict: 'skipped', highest: 'none', canBlock: false }).message,
      'skipped',
    );
  });

  test('the label can be changed', () => {
    assert.equal(securityBadgeFor('{"verdict":"pass"}', 'Scan').label, 'Scan');
  });

  test('anything it does not recognise throws rather than render green', () => {
    for (const raw of [
      'not json',
      '"pass"',
      'null',
      '{"verdict":"passed"}',
      '{"verdict":"informational","highest":"none"}',
      '{"verdict":"informational"}',
    ]) {
      assert.throws(() => securityBadgeFor(raw), BadgeError, raw);
    }
  });
});
