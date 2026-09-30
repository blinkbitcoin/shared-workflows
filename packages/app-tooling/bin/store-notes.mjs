#!/usr/bin/env node
// Store notes for a build, from a release-please body or from
// conventional commit subjects.
//
// The deterministic renderer is the product: it always runs, always produces
// something a store will accept, and is what the optional LLM pass falls back
// to. Nothing here talks to a store -- the lanes read `store-notes.json` and
// `store-notes.txt` (see the consumer's fastlane/lanes/shared.rb `store_notes`).
//
// It runs in the app's repository: the working directory is the app, where
// its commits, its fastlane/metadata/ios locales and its optional
// store-notes.prompt.md are. shared-workflows' scripts/release/store-notes.sh runs
// it from the workflows checkout; on a laptop it is `pnpm exec store-notes`.
//
//   store-notes --from-body RELEASE_BODY.md --out dist/
//   store-notes --from-commits v1.2.0..HEAD --out -
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { isProgram } from '../lib/is-program.mjs';
import { parseEffort, parseExtraParams } from '../lib/llm.mjs';
import { rewriteNotes } from '../lib/store-notes-rewrite.mjs';

/** Store caps, in characters -- which is how both stores count. */
export const STORE_LIMITS = { testflight: 4000, play: 500, appstore: 4000 };
/** Must stay byte-identical to STORE_NOTES_SUFFIX in the consumer's fastlane/lanes/shared.rb. */
export const TRUNCATION_SUFFIX = ' [+more on GitHub]';
/** Groups shown to users, in the order they are rendered. */
const USER_GROUPS = ['New', 'Improved', 'Fixed'];
/** Everything else is changelog-only: real, but not worth a user's attention. */
const OTHER_GROUP = 'Other';
const EMPTY_NOTES = 'Bug fixes and improvements.';
const BULLET = '• ';
/** Opt-in marker that lets a refactor reach users; stripped from the output. */
const USER_VISIBLE_MARKER = /\s*\[user-visible\]\s*/i;

/**
 * The system prompt for the optional LLM pass: this package's, which holds
 * everything the generator depends on (the locales, the limits, the JSON
 * answer it validates), then the app's own addendum, when it keeps one at
 * APP_PROMPT_FILE in its repository, for its product and tone.
 */
export const DEFAULT_PROMPT_FILE = fileURLToPath(new URL('../store-notes.prompt.md', import.meta.url));
export const APP_PROMPT_FILE = 'store-notes.prompt.md';
/** Where the app's store listing locales are, relative to its repository. */
const IOS_METADATA_DIR = path.join('fastlane', 'metadata', 'ios');

const TYPE_GROUPS = { feat: 'New', fix: 'Fixed', perf: 'Improved', refactor: 'Improved' };
/** `type(scope)!: subject` -- the header of a conventional commit. */
const CONVENTIONAL_SUBJECT = /^([a-z]+)(\([^)]*\))?(!)?:\s*(.+)$/i;
const SECTION_GROUPS = {
  features: 'New',
  'bug fixes': 'Fixed',
  'performance improvements': 'Improved',
};

// ---------- text hygiene ----------

/**
 * Everything a store must never see: markdown links and emphasis, bare urls,
 * PR references, commit hashes, ticket keys and bracket tags. Kept separate
 * from `cleanText` because a hand-written `## Store notes` override has to pass
 * through exactly the same filter without being reflowed into one sentence.
 */
export function stripRepoReferences(raw) {
  let text = String(raw);
  // `[label](url)` -> `label`, then bare urls.
  text = text.replace(/\[([^\]]*)\]\([^)]*\)/g, '$1');
  text = text.replace(/<?https?:\/\/\S+/g, '');
  // Trailing `(#128)` / `(9f2c1ab)` decorations, then any stray reference.
  text = text.replace(/\s*\((?:#\d+|[0-9a-f]{7,40})\)/gi, '');
  text = text.replace(/\s*#\d+/g, '');
  text = text.replace(/\s*\b(?=[0-9a-f]{7,40}\b)[0-9a-f]*\d[0-9a-f]*\b/gi, '');
  // Ticket keys (JIRA-123, ENG-7), banned by store-notes.prompt.md.
  text = text.replace(/\b[A-Z][A-Z0-9]+-\d+\b[:\s]*/g, '');
  text = text.replace(USER_VISIBLE_MARKER, ' ');
  // Html tags go whole; emphasis, code spans and bracket tags (`[ios]`,
  // `[WIP]`) lose their punctuation but keep their words. The suffix in
  // TRUNCATION_SUFFIX is added after this runs, so it stays the only pair of
  // square brackets that can reach a store.
  //
  // Stripped until nothing changes, not once: a tag broken open by another tag
  // (`<scr<b>ipt>`) closes up into a new tag after one pass, which is the
  // js/incomplete-multi-character-sanitization finding. The bracket strip
  // below would take that apart anyway, but the loop is what CodeQL reads, and
  // an inline `// codeql[...]` marker cannot close the alert: GitHub ignores the
  // suppression the CLI records (esign, .github/codeql/codeql-config.yml).
  let previous;
  do {
    previous = text;
    text = text.replace(/<\/?[a-z][^>]*>/gi, '');
  } while (text !== previous);
  text = text.replace(/[*_`[\]<>]/g, '');
  return text;
}

/**
 * Strips every trace of the repository from a changelog line and reflows it
 * into one sentence a person can read on a store page.
 */
export function cleanText(raw) {
  let text = String(raw).trim();
  text = text.replace(/^[*-]\s+/, '');
  // `**scope:**` (release-please) before generic emphasis stripping, so that
  // the scope is removed rather than unwrapped into the sentence.
  text = text.replace(/^\*\*[^*]+:\*\*\s*/, '');
  text = stripRepoReferences(text);
  text = text
    .replace(/\s+/g, ' ')
    .replace(/\s+([.,;:!?])/g, '$1')
    .trim();
  text = text.replace(/[\s(,;:-]+$/, '').trim();
  if (!text) return '';
  const sentence = text[0].toUpperCase() + text.slice(1);
  return /[.!?]$/.test(sentence) ? sentence : `${sentence}.`;
}

/**
 * A hand-written `## Store notes` override, made safe for a store while its
 * line structure is left alone: headings lose their `#`, markdown bullets
 * become plain ones, and everything `stripRepoReferences` catches is gone.
 */
export function cleanSection(section) {
  const lines = String(section)
    .split('\n')
    .map((line) => {
      const withoutHeading = line.replace(/^\s*#{1,6}\s*/, '');
      const withBullet = withoutHeading.replace(/^\s*[*-]\s+/, BULLET);
      return stripRepoReferences(withBullet)
        .replace(/[ \t]{2,}/g, ' ')
        .replace(/\s+([.,;:!?])/g, '$1')
        .trimEnd();
    });
  return lines
    .join('\n')
    .replace(/\n{3,}/g, '\n\n')
    .trim();
}

/**
 * `text` cut to `limit` characters at a word boundary, with a pointer to the
 * full changelog. Mirrors `store_notes` in fastlane/lanes/shared.rb: a word
 * boundary is only honoured when it keeps more than half the window, the
 * suffix is dropped when the limit cannot hold it, and the result is never
 * longer than `limit`.
 */
export function limitText(text, limit) {
  const value = String(text).trim();
  if (limit <= 0) return '';
  if (value.length <= limit) return value;
  if (limit <= TRUNCATION_SUFFIX.length) return value.slice(0, limit).trimEnd();

  const window = value.slice(0, limit - TRUNCATION_SUFFIX.length);
  let boundary = -1;
  for (let i = window.length - 1; i >= 0; i -= 1) {
    if (/\s/.test(window[i])) {
      boundary = i;
      break;
    }
  }
  const cut = boundary > window.length / 2 ? window.slice(0, boundary) : window;
  return `${cut.trimEnd()}${TRUNCATION_SUFFIX}`;
}

// ---------- parsing ----------

/** Release-please markdown body -> items. Unknown `###` sections become Other. */
export function parseBody(markdown) {
  const items = [];
  let group = OTHER_GROUP;
  for (const line of String(markdown).split('\n')) {
    const heading = /^#{2,4}\s+(.+?)\s*$/.exec(line);
    if (heading) {
      const name = heading[1].replace(/[*_`]/g, '').trim().toLowerCase();
      group = SECTION_GROUPS[name] ?? OTHER_GROUP;
      continue;
    }
    if (!/^\s*[*-]\s+\S/.test(line)) continue;
    const userVisible = USER_VISIBLE_MARKER.test(line);
    const text = cleanText(line);
    if (!text) continue;
    // The marker is the author saying "this one is worth a user's attention",
    // and it means the same thing in a body as it does in a commit subject.
    items.push({ group: userVisible && group === OTHER_GROUP ? 'Improved' : group, text });
  }
  return items;
}

/** Conventional commit subjects -> items. */
export function parseCommits(subjects) {
  const items = [];
  for (const subject of subjects) {
    const line = String(subject).trim();
    if (!line) continue;
    const match = CONVENTIONAL_SUBJECT.exec(line);
    if (!match) continue;
    const [, rawType, , , described] = match;
    const type = rawType.toLowerCase();
    const userVisible = USER_VISIBLE_MARKER.test(described);
    // `revert: feat(x): thing` carries the reverted commit's own header, which
    // would otherwise reach the notes as the literal scope "Feat(x):".
    let rest = described;
    if (type === 'revert') {
      const inner = CONVENTIONAL_SUBJECT.exec(described);
      rest = `reverted ${inner ? inner[4] : described}`;
    }
    const text = cleanText(rest);
    if (!text) continue;
    // A `refactor` is invisible to users unless its author says otherwise, so
    // it only reaches the notes with the marker; everything else keeps its
    // group. `chore`, `docs`, `ci`, ... fall through to Other by construction.
    const group = TYPE_GROUPS[type] ?? OTHER_GROUP;
    items.push({ group: type === 'refactor' && !userVisible ? OTHER_GROUP : group, text });
  }
  return items;
}

/** `git log --format=%s RANGE` for the repository at `cwd`, defaulting to "since the last tag". */
export function commitSubjects(range, cwd = process.cwd()) {
  // stderr is piped, not inherited: a repo with no tags is an expected state
  // here, and git's "No names found" would otherwise land in the output.
  const git = (...args) =>
    execFileSync('git', args, { cwd, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim();
  let resolved = range;
  if (!resolved) {
    let lastTag = '';
    try {
      lastTag = git('describe', '--tags', '--abbrev=0', '--match', 'v*', 'HEAD');
    } catch {
      lastTag = '';
    }
    resolved = lastTag ? `${lastTag}..HEAD` : 'HEAD';
  }
  const log = git('log', '--format=%s', resolved);
  return log ? log.split('\n') : [];
}

/**
 * The `## Store notes` section of a release body, or '' when there is none.
 *
 * The section ends at the next heading or at a horizontal rule, and HTML
 * comment lines are dropped: the shared workflow wraps the section it appends
 * in `<!-- workflows:append:... -->` markers, and a release PR body closes its
 * content with `---` before release-please's footer. Neither is prose, and a
 * marker that reaches `cleanSection` loses its angle brackets and ships as a
 * literal `!-- ... --` line.
 */
/**
 * A line that is one whole HTML comment. String tests rather than a regex on
 * purpose: the input is one line, so a comment cannot span lines here, and a
 * `<!--.*-->` pattern is what CodeQL's js/bad-tag-filter flags regardless.
 */
function isCommentLine(line) {
  const text = line.trim();
  return text.startsWith('<!--') && text.endsWith('-->');
}

export function extractStoreSection(markdown) {
  const lines = String(markdown).split('\n');
  const start = lines.findIndex((line) => /^#{2,4}\s+store notes\s*$/i.test(line));
  if (start === -1) return '';
  const rest = lines.slice(start + 1);
  const end = rest.findIndex((line) => /^#{1,4}\s+\S|^\s*-{3,}\s*$/.test(line));
  return (end === -1 ? rest : rest.slice(0, end))
    .filter((line) => !isCommentLine(line))
    .join('\n')
    .trim();
}

// ---------- rendering ----------

/** Grouped bullets, in plain text. Empty input gets one honest line. */
export function renderNotes(items) {
  const blocks = [];
  for (const group of USER_GROUPS) {
    const texts = items.filter((item) => item.group === group).map((item) => item.text);
    if (texts.length) blocks.push([group, ...texts.map((t) => `${BULLET}${t}`)].join('\n'));
  }
  return blocks.length ? blocks.join('\n\n') : EMPTY_NOTES;
}

/**
 * The compact, complete list -- including the work that never reaches the
 * user-facing groups. Deliberately denser than the prose it follows: it has to
 * survive Google Play's 500 characters alongside it.
 */
export function renderChangelog(items) {
  const lines = [];
  for (const group of [...USER_GROUPS, OTHER_GROUP]) {
    const texts = items.filter((item) => item.group === group).map((item) => item.text);
    if (texts.length) lines.push(`${group}: ${texts.join(' ')}`);
  }
  return lines.length ? ['Changelog', ...lines].join('\n') : '';
}

/** A prompt file's text, or '' when the file is not there. */
export function loadPrompt(file = DEFAULT_PROMPT_FILE) {
  return existsSync(file) ? readFileSync(file, 'utf8') : '';
}

/**
 * The whole system prompt: the package's, then the app's addendum after a
 * blank line. An app without one gets the package's alone; either part may be
 * empty, and the LLM pass declines only when both are.
 */
export function composePrompt(base, addendum) {
  return [base, addendum]
    .map((part) => String(part ?? '').trim())
    .filter(Boolean)
    .join('\n\n');
}

/** Locale directories under fastlane/metadata/ios (`review_information` is not one). */
export function discoverLocales(dir = path.resolve(IOS_METADATA_DIR)) {
  if (!existsSync(dir)) return ['en-US'];
  const locales = readdirSync(dir, { withFileTypes: true })
    .filter((entry) => entry.isDirectory() && /^[a-z]{2}(-[A-Za-z]{2,4})?$/.test(entry.name))
    .map((entry) => entry.name)
    .sort();
  return locales.length ? locales : ['en-US'];
}

/** `{locale: {testflight, play, appstore}}` from one text per locale. */
export function toStoreNotes(textByLocale) {
  const notes = {};
  for (const [locale, text] of Object.entries(textByLocale)) {
    notes[locale] = {
      testflight: limitText(text, STORE_LIMITS.testflight),
      play: limitText(text, STORE_LIMITS.play),
      appstore: limitText(text, STORE_LIMITS.appstore),
    };
  }
  return notes;
}

/**
 * The whole pipeline: items in, one text per locale out. `rewrite` is the LLM
 * pass; it returns null whenever it cannot be trusted, and this falls back to
 * the deterministic prose without saying anything else about it.
 */
export async function buildNotes({
  items,
  locales,
  verbatim = '',
  includeChangelog = false,
  provider,
  model,
  effort,
  extraParams,
  prompt,
  fetchImpl,
  rewrite = rewriteNotes,
}) {
  const prose = renderNotes(items);
  let byLocale = Object.fromEntries(locales.map((locale) => [locale, verbatim || prose]));

  if (!verbatim && provider && provider !== 'none') {
    const rewritten = await rewrite({
      items,
      prompt,
      locales,
      provider,
      model,
      effort,
      extraParams,
      fetchImpl,
    });
    if (rewritten) byLocale = rewritten;
  }

  // A verbatim section is final: it is the reviewed text the release PR
  // carried, and the changelog was appended where that text was generated.
  if (includeChangelog && !verbatim) {
    const changelog = renderChangelog(items);
    if (changelog) {
      byLocale = Object.fromEntries(
        Object.entries(byLocale).map(([locale, text]) => [locale, `${text}\n\n${changelog}`]),
      );
    }
  }
  return byLocale;
}

// ---------- CLI ----------

export const USAGE = `usage: store-notes (--from-body FILE | --from-commits [RANGE] | --tag TAG | --pr N | --preview) [options]

Store notes for a build, from a release-please body or from
conventional commit subjects, for the app in the working directory. Nothing
here talks to a store: the lanes read store-notes.json and store-notes.txt
(fastlane/lanes/shared.rb). An LLM pass runs when $STORE_NOTES_LLM_PROVIDER
is set; ./store-notes.prompt.md is added to its prompt when present.

  --from-body FILE      render from a release body (e.g. the GitHub release)
  --from-commits [R]    render from conventional commit subjects in range R
  --tag TAG             render from release TAG's body (gh release view), with --body-section
  --pr N                render from pull request N's body (gh pr view), with --body-section
  --preview             render from --tag or --pr when given, else $TAG or $PR,
                        else the commits since the last v* tag (what make store-notes runs)
  --body-section        also take a verbatim "## Store notes" section from the body
  --locales a,b         locales to emit (default: $STORE_NOTES_LOCALES, else
                        the locale directories under fastlane/metadata/ios)
  --include-changelog   append the full changelog (also $STORE_NOTES_INCLUDE_CHANGELOG)
  --out DIR|-           write store-notes.json + store-notes.txt into DIR, or - for stdout
  --help                this text

  store-notes --from-body RELEASE_BODY.md --out dist/
  store-notes --from-commits v1.2.0..HEAD --out -
  TAG=v1.4.0 store-notes --preview`;

/** The flags that each name where the changes come from; at most one may be given. */
const SOURCE_FLAGS = ['--from-body', '--from-commits', '--tag', '--pr'];

export function parseArgs(argv) {
  const options = {
    fromBody: '',
    fromCommits: false,
    range: '',
    tag: '',
    pr: '',
    preview: false,
    locales: [],
    out: '',
    includeChangelog: process.env.STORE_NOTES_INCLUDE_CHANGELOG === 'true',
    bodySection: false,
  };
  const sources = [];
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    const next = () => {
      i += 1;
      if (argv[i] === undefined) throw new Error(`${arg} needs a value`);
      return argv[i];
    };
    if (SOURCE_FLAGS.includes(arg)) sources.push(arg);
    if (arg === '--from-body') options.fromBody = next();
    else if (arg === '--from-commits') {
      options.fromCommits = true;
      if (argv[i + 1] && !argv[i + 1].startsWith('--')) options.range = next();
    } else if (arg === '--tag') options.tag = next();
    else if (arg === '--pr') options.pr = next();
    else if (arg === '--preview') options.preview = true;
    else if (arg === '--locales') options.locales = next().split(',').filter(Boolean);
    else if (arg === '--out') options.out = next();
    else if (arg === '--include-changelog') options.includeChangelog = true;
    else if (arg === '--body-section') options.bodySection = true;
    else throw new Error(`unknown argument: ${arg}`);
  }
  if (sources.length > 1) {
    throw new Error(`${sources.join(' and ')} are mutually exclusive: give one source of changes`);
  }
  if (!sources.length && !options.preview) {
    throw new Error('one of --from-body FILE, --from-commits [RANGE], --tag TAG, --pr N or --preview is required');
  }
  return options;
}

/**
 * `options` with its source settled. `--preview` is the laptop preview `make
 * store-notes` runs: with no source flag it takes `$TAG`, then `$PR`, the
 * variables make passes through from its command line, and otherwise the
 * commits since the last tag. Only `--preview` reads them: they are common
 * names, and a CI step that happens to carry one must not change its source.
 * A release or pull request body always means `--body-section`, as the recipe
 * this replaced did, so a reviewed `## Store notes` section is what shows.
 */
export function resolveSource(options, env = process.env) {
  const resolved = { ...options };
  let prFrom = '--pr';
  if (resolved.preview && !resolved.fromBody && !resolved.fromCommits && !resolved.tag && !resolved.pr) {
    const tag = String(env.TAG ?? '').trim();
    const pr = String(env.PR ?? '').trim();
    if (tag && pr) throw new Error('TAG and PR are mutually exclusive: give one of them, or neither to preview from the commits');
    resolved.tag = tag;
    resolved.pr = pr;
    prFrom = 'PR';
    if (!tag && !pr) resolved.fromCommits = true;
  }
  if (resolved.pr && !/^[1-9]\d*$/.test(resolved.pr)) {
    throw new Error(`${prFrom} takes a pull request number, got ${JSON.stringify(resolved.pr)}`);
  }
  if (resolved.tag || resolved.pr) resolved.bodySection = true;
  return resolved;
}

/**
 * The body of release `tag` or pull request `pr` in the repository at `cwd`,
 * read with the GitHub CLI through `exec` (execFileSync's shape). A missing
 * CLI, a tag or pull request that is not there, and an empty body each fail
 * with the reason: previewing an empty body would look like a release with
 * nothing in it.
 */
export function fetchBody({ tag, pr }, { cwd = process.cwd(), exec = execFileSync } = {}) {
  const [kind, id, what] = tag ? ['release', tag, `release ${tag}`] : ['pr', pr, `pull request ${pr}`];
  const args = [kind, 'view', id, '--json', 'body', '-q', '.body'];
  let body;
  try {
    body = exec('gh', args, { cwd, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
  } catch (failure) {
    if (failure.code === 'ENOENT') {
      throw new Error('gh is not installed: --tag and --pr read the body with the GitHub CLI (https://cli.github.com)');
    }
    const reason = String(failure.stderr || failure.message).trim().split('\n')[0];
    throw new Error(`gh ${kind} view ${id} failed: ${reason}`);
  }
  if (!String(body).trim()) throw new Error(`the body of ${what} is empty`);
  return String(body);
}

/**
 * The locales to emit notes for, most specific source first:
 *
 *   1. `--locales a,b`
 *   2. `$STORE_NOTES_LOCALES` — what the reusable `build-prepare` workflow exports for
 *      its `store-notes-locales` input. Reading it here is what makes that input do
 *      something; it was plumbed through and silently ignored.
 *   3. the locale directories under `cwd`'s fastlane/metadata/ios, which are
 *      the ones the lanes then look up in store-notes.json.
 *
 * A caller that sets `store-notes-locales` must therefore use the *metadata* locale
 * names (`en-US`, not `en`): a key the lanes do not look up sends every locale
 * back to the single-locale fallback and throws the LLM pass away.
 */
export function resolveLocales(options, env = process.env, cwd = process.cwd()) {
  if (options.locales.length) return options.locales;
  const fromEnv = String(env.STORE_NOTES_LOCALES ?? '')
    .split(',')
    .map((locale) => locale.trim())
    .filter(Boolean);
  return fromEnv.length ? fromEnv : discoverLocales(path.resolve(cwd, IOS_METADATA_DIR));
}

/**
 * Command-line entry; returns the exit code. Any failure is one line on stderr
 * and exit 1. `rewrite` is the LLM pass, injectable like `buildNotes`'s, and
 * `exec` runs `gh` for --tag and --pr (execFileSync's shape).
 */
export async function main(
  argv = process.argv.slice(2),
  {
    cwd = process.cwd(),
    env = process.env,
    write = (text) => process.stdout.write(text),
    error = console.error,
    rewrite = rewriteNotes,
    exec = execFileSync,
  } = {},
) {
  try {
    await run(argv, { cwd, env, write, error, rewrite, exec });
    return 0;
  } catch (failure) {
    error(String(failure.message ?? failure));
    return 1;
  }
}

async function run(argv, { cwd, env, write, error, rewrite, exec }) {
  if (argv.includes('--help') || argv.includes('-h')) {
    write(`${USAGE}\n`);
    return;
  }
  const options = resolveSource(parseArgs(argv), env);
  const locales = resolveLocales(options, env, cwd);

  let items = [];
  let verbatim = '';
  if (options.fromBody || options.tag || options.pr) {
    const body = options.fromBody
      ? readFileSync(path.resolve(cwd, options.fromBody), 'utf8')
      : fetchBody(options, { cwd, exec });
    items = parseBody(body);
    // A hand-written override is still repository prose: it goes through the
    // same filter as everything the renderer produces.
    if (options.bodySection) verbatim = cleanSection(extractStoreSection(body));
  } else {
    items = parseCommits(commitSubjects(options.range, cwd));
  }

  const byLocale = await buildNotes({
    items,
    locales,
    verbatim,
    includeChangelog: options.includeChangelog,
    provider: env.STORE_NOTES_LLM_PROVIDER,
    model: env.STORE_NOTES_LLM_MODEL,
    // Parsed here, before anything is sent: a typo in either is the run's
    // failure, not a quietly shallower rewrite.
    effort: parseEffort(env.STORE_NOTES_LLM_EFFORT, 'STORE_NOTES_LLM_EFFORT'),
    extraParams: parseExtraParams(
      env.STORE_NOTES_LLM_EXTRA_PARAMS,
      'STORE_NOTES_LLM_EXTRA_PARAMS',
    ),
    prompt: composePrompt(loadPrompt(), loadPrompt(path.resolve(cwd, APP_PROMPT_FILE))),
    rewrite,
  });
  const notes = toStoreNotes(byLocale);
  const primary = notes['en-US'] ? 'en-US' : locales[0];
  const json = `${JSON.stringify(notes, null, 2)}\n`;

  if (!options.out || options.out === '-') {
    write(json);
    return;
  }
  const outDir = path.resolve(cwd, options.out);
  mkdirSync(outDir, { recursive: true });
  writeFileSync(path.join(outDir, 'store-notes.json'), json);
  writeFileSync(path.join(outDir, 'store-notes.txt'), `${notes[primary].testflight}\n`);
  error(`store notes written to ${outDir} (${locales.join(', ')})`);
}

if (isProgram(import.meta.url, process.argv[1])) process.exitCode = await main();
