// The provider-portable half of every LLM call this family makes: which
// adapter a provider name means, which key it needs, and the two settings that
// travel beside the model. The store-notes rewrite (store-notes-rewrite.mjs)
// the security reviewer (security-review.mjs) and a consumer's own callers all
// come through here (`@blinkbitcoin/app-tooling/llm`), so a provider that works
// for one works for the others.
import * as anthropic from './llm-anthropic.mjs';
import * as openai from './llm-openai.mjs';

const ADAPTERS = { anthropic, openai };
export const KEY_ENV = { anthropic: 'ANTHROPIC_API_KEY', openai: 'OPENAI_API_KEY' };
export const EFFORTS = ['none', 'low', 'medium', 'high', 'max'];

/**
 * An effort setting, `max` when unset; `none` is for a model with no reasoning
 * switch. Anything else throws: a typo must not quietly buy a shallower answer
 * than the one asked for.
 */
export const parseEffort = (value, source) => {
  if (value === undefined || value === '') return 'max';
  if (!EFFORTS.includes(value)) {
    throw new Error(
      `${source}: expected one of ${EFFORTS.join(', ')}, got ${JSON.stringify(value)}`,
    );
  }
  return value;
};

// The request fields an extra-parameters object may not replace: overriding
// them would change who is asked, or what, rather than how.
const PROTECTED = new Set(['model', 'messages', 'system']);

/**
 * Vendor-specific request fields (Qwen's `enable_thinking`, OpenRouter's
 * `reasoning`, Kimi's `thinking`), as a JSON object merged into the top of the
 * request body; a key set to null removes that field from the request (an
 * endpoint that rejects `response_format`, say). Empty means none. The value is never echoed into an error: it is an arbitrary
 * string from the environment, and an error message ends up in a CI log.
 */
export const parseExtraParams = (value, source) => {
  if (value === undefined || value === '') return {};
  let parsed;
  try {
    parsed = JSON.parse(value);
  } catch {
    throw new Error(`${source}: not valid JSON`);
  }
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
    throw new Error(`${source}: expected a JSON object`);
  }
  for (const key of Object.keys(parsed)) {
    if (PROTECTED.has(key)) throw new Error(`${source}: may not set ${key}`);
  }
  return parsed;
};

/** The adapter for a provider name, or null when the name is not one. */
export const adapterFor = (provider) =>
  Object.hasOwn(ADAPTERS, provider) ? ADAPTERS[provider] : null;
