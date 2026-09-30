// Anthropic Messages API over plain fetch. No SDK on purpose: this package
// has no dependencies, and the request is one POST.
// https://docs.anthropic.com/en/api/messages
import { mergeRequest, thinks } from './llm-request.mjs';

export const DEFAULT_MODEL = 'claude-sonnet-5';
const ENDPOINT = 'https://api.anthropic.com/v1/messages';
const API_VERSION = '2023-06-01';
const DEFAULT_MAX_TOKENS = 2048;

/**
 * The assistant's text for one system+user turn. Throws on any API failure,
 * and on a refusal: a declined request has no answer to validate.
 *
 * `effort` is this family's word (low|medium|high|max) and maps one to one
 * onto `output_config.effort`; `none` sends neither field. Thinking is asked for as adaptive rather than
 * left out: on some current models an absent `thinking` means none at all,
 * and effort only buys depth when the model is allowed to think.
 * `extraParams` is merged into the body last, for a switch this adapter does
 * not know by name; a null value removes that field (see llm-request.mjs).
 */
export async function complete({
  system,
  user,
  model,
  maxTokens = DEFAULT_MAX_TOKENS,
  effort,
  extraParams = {},
  fetchImpl = globalThis.fetch,
}) {
  const response = await fetchImpl(ENDPOINT, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      'x-api-key': process.env.ANTHROPIC_API_KEY ?? '',
      'anthropic-version': API_VERSION,
    },
    body: JSON.stringify(
      mergeRequest(
        {
          model: model || DEFAULT_MODEL,
          max_tokens: maxTokens,
          ...(thinks(effort) ? { thinking: { type: 'adaptive' }, output_config: { effort } } : {}),
          system,
          messages: [{ role: 'user', content: user }],
        },
        extraParams,
      ),
    ),
  });
  if (!response.ok) throw new Error(`anthropic: HTTP ${response.status}`);
  const payload = await response.json();
  if (payload?.stop_reason === 'refusal')
    throw new Error('anthropic: the model declined the request');
  const text = payload?.content?.find?.((block) => block?.type === 'text')?.text;
  if (typeof text !== 'string') throw new Error('anthropic: no text block in response');
  return text;
}
