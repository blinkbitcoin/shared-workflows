// A local stand-in for an OpenAI-compatible chat completions endpoint, for the
// tests that run the store notes generator with a model: the store-notes app
// suite and the chain test in this repository. Point OPENAI_BASE_URL at
// `baseUrl` and every request is recorded and answered by `reply`.
import { createServer } from 'node:http';

/**
 * Starts the stub on a free port on the loopback interface. `reply(body)` gets
 * each parsed request body and returns `{ status, content }`: the HTTP status
 * and the assistant message's content. Resolves to the requests seen so far,
 * the base URL to use, and `close()`.
 */
export async function startOpenAiStub(reply) {
  const requests = [];
  const server = createServer((request, response) => {
    let text = '';
    request.on('data', (chunk) => {
      text += chunk;
    });
    request.on('end', () => {
      const body = JSON.parse(text);
      requests.push({ url: request.url, body });
      const { status, content } = reply(body);
      response.writeHead(status, { 'content-type': 'application/json' });
      response.end(JSON.stringify({ choices: [{ message: { content } }] }));
    });
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const { port } = server.address();
  return {
    requests,
    baseUrl: `http://127.0.0.1:${port}/v1`,
    close: () => new Promise((resolve) => server.close(resolve)),
  };
}

/** The system message of a chat completions request body, or '' when it has none. */
export function systemPrompt(body) {
  return body.messages?.find((message) => message.role === 'system')?.content ?? '';
}
