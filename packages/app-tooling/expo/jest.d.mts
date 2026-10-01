import type { Config } from 'jest';

export interface JestPresetOptions {
  /** The app project's `setupFiles` (environment variables). */
  setupFiles?: string[];
  /** The app project's own setup files; the console guard is appended. */
  setupFilesAfterEnv?: string[];
  /** The app's aliases, matched before the Expo stand-ins. */
  moduleNameMapper?: Record<string, string>;
  /** Appended to the generic list, in both projects. */
  coveragePathIgnorePatterns?: string[];
  /** Appended to the app project's generic list. */
  testPathIgnorePatterns?: string[];
  /** More packages the app project has to transform. */
  transformPackages?: string[];
  /** Replaces the generic list. */
  collectCoverageFrom?: string[];
  /** False leaves the silent-tests guard out. */
  consoleGuard?: boolean;
}

export const WORKTREES: string;
export const WORKFLOWS: string;
export const IGNORED_DIRECTORIES: string[];
export const CONSOLE_SETUP: string;
export const EXPO_MOCKS: Record<string, string>;
export const COVERAGE_PATH_IGNORE_PATTERNS: string[];
export const TRANSFORM_PACKAGES: string[];
export const TEST_PATH_IGNORE_PATTERNS: string[];
export const COLLECT_COVERAGE_FROM: string[];
export function transformIgnorePattern(packages: string[]): string;
export function createJestConfig(options?: JestPresetOptions): Config;
