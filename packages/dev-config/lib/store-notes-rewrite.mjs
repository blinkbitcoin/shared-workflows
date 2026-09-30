// Optional LLM rewrite of the deterministic store notes.
//
// The contract with the caller is one-way: this returns `{locale: text}` only
// when the model's answer passes every check, and `null` otherwise. Every
// failure -- no key, HTTP error, unparsable JSON, a missing locale, a leaked
// commit hash -- is a warning on stderr and a fall back to the deterministic
// prose. A release must never fail because a model was unavailable.
import { adapterFor, KEY_ENV } from './llm.mjs';
import { thinks, unfence } from './llm-request.mjs';

/** The tightest limit the text must fit before per-store cuts are applied. */
export const TESTFLIGHT_LIMIT = 4000;

/** The placeholders the prompt may use: `{{locales}}` and `{{limit}}`. */
const PLACEHOLDER = /\{\{(\w+)\}\}/g;

/**
 * The prompt template with its placeholders filled in. An unknown placeholder
 * throws: a typo in the template would otherwise reach the model as literal
 * braces and pass every check.
 */
export function renderPrompt(template, values) {
  return String(template).replace(PLACEHOLDER, (_, key) => {
    if (!Object.hasOwn(values, key)) throw new Error(`unknown placeholder {{${key}}} in prompt`);
    return String(values[key]);
  });
}

/** Room for the model's thinking, the same allowance the security review has. */
const THINKING_TOKENS = 16000;

/**
 * Enough output tokens for every requested locale to reach the TestFlight cap.
 * A fixed budget truncates the JSON mid-object once a release asks for more
 * than a couple of locales, and a truncated response is a silent fallback.
 * Thinking tokens count against the same budget on both APIs, so an effort
 * that thinks gets its allowance on top; without it the thinking can spend the
 * whole budget and leave no text.
 */
export function maxTokensFor(locales, effort) {
  const text = Math.min(8192, 1024 + locales.length * 1500);
  return thinks(effort) ? text + THINKING_TOKENS : text;
}

/** The user turn: the deterministic items, grouped, plus the locales wanted. */
function buildUserPrompt(items, locales) {
  const lines = items.map((item) => `- [${item.group}] ${item.text}`);
  return [
    'Changes in this release:',
    lines.length ? lines.join('\n') : '(no user-facing changes)',
    '',
    `Locales: ${locales.join(', ')}`,
  ].join('\n');
}

/** Top-level domains common enough that a bare one is almost certainly a link. */
const LINKISH_TLDS = 'com|io|dev|app|net|org|co|ai|sh|me|gg';

/** Reasons `text` cannot be shipped to a store, in the order they are checked. */
function violations(text) {
  const found = [];
  if (!text.trim()) found.push('empty');
  if (text.includes('#')) found.push('contains "#"');
  if (text.includes('[')) found.push('contains markdown link syntax');
  if (/https?:\/\//i.test(text)) found.push('contains a link');
  // A bare `example.com/promo` is a link a person can still type in, and the
  // path is what separates it from a sentence that happens to name a product.
  if (new RegExp(`\\b[a-z0-9-]+\\.(?:${LINKISH_TLDS})\\b/`, 'i').test(text)) {
    found.push('contains a domain');
  }
  if (/(?:^|\n)\s*[*-]\s|\*\*|__/.test(text)) found.push('contains markdown');
  // A line of dashes is where release-please splits a PR body into the release
  // notes, and any tag (a `<details>` block, a comment) is parsed by GitHub or
  // by the shared workflow rather than read by a person.
  if (/^\s*-{3,}\s*$/m.test(text)) found.push('contains a horizontal rule');
  if (/<[a-z!/]/i.test(text)) found.push('contains html');
  if (/\b(?=[0-9a-f]{7,40}\b)[0-9a-f]*\d[0-9a-f]*\b/i.test(text)) found.push('contains a hash');
  if (text.length > TESTFLIGHT_LIMIT) found.push(`longer than ${TESTFLIGHT_LIMIT} characters`);
  return found;
}

/** `{locale: text}` when every requested locale validates, otherwise null. */
export function validate(raw, locales) {
  let parsed;
  try {
    parsed = JSON.parse(unfence(raw));
  } catch {
    return { error: 'response is not JSON' };
  }
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
    return { error: 'response is not a JSON object' };
  }
  const notes = {};
  for (const locale of locales) {
    const value = parsed[locale];
    if (typeof value !== 'string') return { error: `missing locale ${locale}` };
    const problems = violations(value);
    if (problems.length) return { error: `${locale}: ${problems.join(', ')}` };
    notes[locale] = value.trim();
  }
  return { notes };
}

/**
 * Rewritten notes per locale, or null when the rewrite cannot be trusted.
 * `provider` is `anthropic`, `openai`, or anything else (meaning: don't).
 * `effort` and `extraParams` are passed to the adapter as they are
 * (llm.mjs parses both from the environment).
 * `prompt` is the whole system prompt as a template: the package's
 * store-notes.prompt.md, then the app's release-notes.prompt.md when it has one.
 */
export async function rewriteNotes({
  items,
  prompt,
  locales,
  provider,
  model,
  effort,
  extraParams,
  fetchImpl,
}) {
  const adapter = adapterFor(provider);
  if (!adapter) return null;

  if (!process.env[KEY_ENV[provider]]) {
    console.warn(`release notes: ${KEY_ENV[provider]} is not set, keeping the generated notes`);
    return null;
  }

  if (!prompt?.trim()) {
    console.warn('release notes: the prompt is empty, keeping the generated notes');
    return null;
  }
  const system = renderPrompt(prompt.trim(), {
    locales: locales.join(', '),
    limit: TESTFLIGHT_LIMIT,
  });
  let raw;
  try {
    raw = await adapter.complete({
      maxTokens: maxTokensFor(locales, effort),
      system,
      user: buildUserPrompt(items, locales),
      model,
      effort,
      extraParams,
      fetchImpl,
    });
  } catch (error) {
    console.warn(
      `release notes: ${provider} rewrite failed (${error.message}), keeping the generated notes`,
    );
    return null;
  }

  const result = validate(raw, locales);
  if (result.error) {
    console.warn(
      `release notes: ${provider} rewrite rejected (${result.error}), keeping the generated notes`,
    );
    return null;
  }
  return result.notes;
}
