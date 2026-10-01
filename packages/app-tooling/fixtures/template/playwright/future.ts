// WEB ONLY
// The web suite against the exported site and the mock API. Ports and base
// path come from the environment `make test-e2e-web` exports.
import { createPlaywrightConfig } from '@blinkbitcoin/app-tooling/expo/playwright';
import { defineConfig } from '@playwright/test';

export default defineConfig(createPlaywrightConfig({ mockApiCommand: 'pnpm dev:api' }));
