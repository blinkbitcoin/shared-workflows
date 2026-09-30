import type { Linter } from 'eslint';

export interface EslintPresetOptions {
  /** Appended to the generic ignores (generated code, say). */
  ignores?: string[];
  /** Appended to the files that get Node's globals. */
  nodeFiles?: string[];
}

export const IGNORES: string[];
export const BIOME_OWNED_RULES: Linter.RulesRecord;
export const NODE_FILES: string[];
export function createEslintConfig(options?: EslintPresetOptions): Linter.Config[];
