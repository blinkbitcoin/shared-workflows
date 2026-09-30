import type { PlaywrightTestConfig } from '@playwright/test';

export interface PlaywrightPresetOptions {
  /** Where the ports and base path are read from; process.env by default. */
  env?: Record<string, string | undefined>;
  testDir?: string;
  /** Starts the mock API at EXPO_PUBLIC_API_URL. */
  mockApiCommand?: string;
  /** Serves the export at WEB_PREVIEW_PORT. */
  previewCommand?: string;
}

export function createPlaywrightConfig(options?: PlaywrightPresetOptions): PlaywrightTestConfig;
