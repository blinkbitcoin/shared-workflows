#!/usr/bin/env node
// Serves a web export the way GitHub Pages serves it, for a Playwright suite to
// test: under the base path the export was built for, `/settings` from
// `settings.html`, `/details/` from `details/index.html`, and `404.html` with a
// 404 for a path with no file - which is how a deep link into a dynamic route
// boots the router on Pages. `expo serve` cannot stand in: it serves at `/` only.
//
//   serve-dist            serves dist/ in the current directory
//   serve-dist DIRECTORY  serves that directory instead
//
// The port is WEB_PREVIEW_PORT and the base path EXPO_PUBLIC_BASE_URL, both
// from the environment: an app derives its ports its own way and exports them
// before the suite starts, so nothing here chooses one. The expo/playwright
// preset starts this as its preview server.
import { createReadStream, existsSync, statSync } from 'node:fs';
import { createServer } from 'node:http';
import path from 'node:path';
import { isProgram } from '../lib/is-program.mjs';

const TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.map': 'application/json; charset=utf-8',
  '.png': 'image/png',
  '.ico': 'image/x-icon',
  '.svg': 'image/svg+xml',
  '.ttf': 'font/ttf',
  '.woff2': 'font/woff2',
};

/** Trailing slashes off, exactly one leading slash on; '' for the root. */
export function normalizeBasePath(raw) {
  const trimmed = (raw ?? '').trim().replace(/\/+$/, '');
  if (trimmed === '') return '';
  return trimmed.startsWith('/') ? trimmed : `/${trimmed}`;
}

/**
 * Maps a request path to a file under `dist`, or to the 404 page.
 * Returns { file, status } where file is absolute, or null when the path is
 * outside the base path (Pages would serve another site there).
 */
export function resolveRequest(dist, basePath, urlPath) {
  const decoded = decodeURIComponent(urlPath.split('?')[0]);
  if (basePath && decoded !== basePath && !decoded.startsWith(`${basePath}/`)) return null;
  let rel = basePath ? decoded.slice(basePath.length) : decoded;
  if (rel === '' || rel === '/') rel = '/index.html';
  const candidate = path.resolve(dist, `.${rel}`);
  if (!candidate.startsWith(`${path.resolve(dist)}${path.sep}`))
    return { file: path.join(dist, '404.html'), status: 404 };
  const tries = [candidate, `${candidate}.html`, path.join(candidate, 'index.html')];
  for (const file of tries) {
    if (existsSync(file) && statSync(file).isFile()) return { file, status: 200 };
  }
  return { file: path.join(dist, '404.html'), status: 404 };
}

export function startServer({ dist, basePath, port }) {
  const server = createServer((req, res) => {
    const hit = resolveRequest(dist, basePath, req.url ?? '/');
    if (!hit || !existsSync(hit.file)) {
      res.writeHead(404, { 'content-type': 'text/plain' });
      res.end('not found');
      return;
    }
    res.writeHead(hit.status, {
      'content-type': TYPES[path.extname(hit.file)] ?? 'application/octet-stream',
      'cache-control': 'no-store',
    });
    createReadStream(hit.file).pipe(res);
  });
  server.listen(port);
  return server;
}

/**
 * Command-line entry: starts the server and returns 0 (the open server keeps
 * the process alive), or returns 1 when no port is configured or there is no
 * export to serve.
 */
export function main(
  argv = process.argv.slice(2),
  { env = process.env, cwd = process.cwd(), start = startServer, log = console.log, error = console.error } = {},
) {
  const dist = path.resolve(cwd, argv[0] ?? 'dist');
  const basePath = normalizeBasePath(env.EXPO_PUBLIC_BASE_URL);
  const port = Number(env.WEB_PREVIEW_PORT);
  if (!port) {
    error('WEB_PREVIEW_PORT is not set; export the port the suite expects the preview on before starting it');
    return 1;
  }
  if (!existsSync(dist) || !statSync(dist).isDirectory()) {
    error(`no web export at ${dist}; export the site first (the app's build:web)`);
    return 1;
  }
  start({ dist, basePath, port });
  log(`serving ${dist} at http://localhost:${port}${basePath || '/'} (404 -> 404.html)`);
  return 0;
}

if (isProgram(import.meta.url, process.argv[1])) process.exitCode = main();
