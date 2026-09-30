export interface FingerprintPresetOptions {
  /** Appended to the generic list. */
  ignorePaths?: string[];
}

export interface FingerprintConfig {
  sourceSkips: string[];
  ignorePaths: string[];
}

export const SOURCE_SKIPS: string[];
export const IGNORE_PATHS: string[];
export function createFingerprintConfig(options?: FingerprintPresetOptions): FingerprintConfig;
