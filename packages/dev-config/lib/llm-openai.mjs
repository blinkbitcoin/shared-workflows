// OpenAI chat completions over plain fetch. OPENAI_BASE_URL points it at any
// compatible endpoint - OpenRouter, Gemini, Groq, Mistral, DeepSeek, Kimi,
// Qwen, GitHub Models, a local Ollama - which is what makes the LLM jobs
// portable across providers. The store notes section of shared-workflows'
// docs/consumer-guide.md has the settings.
import { mergeRequest, thinks } from './llm-request.mjs';

export const DEFAULT_MODEL = 'gpt-5';
const DEFAULT_BASE = 'https://api.openai.com/v1';
const DEFAULT_MAX_TOKENS = 2048;

// OpenAI's schema tops out at `high`; this family's `max` asks for the most
// the endpoint will give. `none` sends no `reasoning_effort` at all.
const REASONING_EFFORT = { low: 'low', medium: 'medium', high: 'high', max: 'high' };

/**
 * The assistant's text for one system+user turn. Throws on any API failure.
 *
 * `max_completion_tokens` is OpenAI's own name, which its reasoning models
 * require; most compatible endpoints only know the older `max_tokens`, and
 * reject or ignore the new one. The base URL decides which is sent, and
 * `extraParams` can swap it: `{"max_tokens": null, "max_completion_tokens": 4000}`.
 * Any other default an endpoint rejects is dropped the same way, with null.
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
  const base = process.env.OPENAI_BASE_URL || DEFAULT_BASE;
  const official = new URL(base).hostname === 'api.openai.com';
  const response = await fetchImpl(`${base}/chat/completions`, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      authorization: `Bearer ${process.env.OPENAI_API_KEY ?? ''}`,
    },
    body: JSON.stringify(
      mergeRequest(
        {
          model: model || DEFAULT_MODEL,
          [official ? 'max_completion_tokens' : 'max_tokens']: maxTokens,
          ...(thinks(effort) ? { reasoning_effort: REASONING_EFFORT[effort] } : {}),
          response_format: { type: 'json_object' },
          messages: [
            { role: 'system', content: system },
            { role: 'user', content: user },
          ],
        },
        extraParams,
      ),
    ),
  });
  if (!response.ok) throw new Error(`openai: HTTP ${response.status}`);
  const payload = await response.json();
  const text = payload?.choices?.[0]?.message?.content;
  if (typeof text !== 'string') throw new Error('openai: no message content in response');
  return text;
}
