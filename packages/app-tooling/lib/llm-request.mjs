// The request and response rules both adapters share. They live apart from
// llm.mjs because llm.mjs imports the adapters, and the adapters need these.

/**
 * Whether an effort asks the model to think. `none` is for a model with no
 * reasoning switch at all (most Llama, Mistral and Gemma models, gpt-4.1):
 * those answer HTTP 400 to any effort field, so none is sent.
 */
export const thinks = (effort) => Boolean(effort) && effort !== 'none';

/**
 * `body` with the extra parameters merged over its top level. A key set to
 * null removes that field instead, which is how an endpoint that rejects a
 * default field (`response_format`, or `max_tokens` where it wants
 * `max_completion_tokens`) is still reachable from configuration alone.
 */
export function mergeRequest(body, extraParams = {}) {
  const merged = { ...body, ...extraParams };
  for (const [key, value] of Object.entries(extraParams)) {
    if (value === null) delete merged[key];
  }
  return merged;
}

/**
 * The answer with one surrounding markdown code fence removed. A model with no
 * JSON mode (Anthropic has none, nor do many compatible endpoints) sometimes
 * fences its JSON; the fence is packaging, not a malformed answer.
 */
export function unfence(raw) {
  const fenced = /^\s*```(?:json)?\s*\n([\s\S]*?)\n\s*```\s*$/.exec(raw);
  return fenced ? fenced[1] : raw;
}
