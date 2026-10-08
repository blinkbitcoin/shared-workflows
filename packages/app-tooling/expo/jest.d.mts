import type { Config } from 'jest';

export interface JestPresetOptions {
  /** The app project's `setupFiles` (environment variables). */
  setupFiles?: string[];
  /** The app project's own setup files; the console guard is appended. */
  setupFilesAfterEnv?: string[];
  /** The app's aliases, matched after msw 3's `fetch` mapping (the same key replaces it) and before the Expo stand-ins. */
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
  /** Where jest-expo and msw are read from; the working directory by default. */
  appRoot?: string;
}

/** A Jest `transform` entry: the transformer and its options. */
export type TransformEntry = [string, Record<string, unknown>];

export const WORKTREES: string;
export const WORKFLOWS: string;
export const IGNORED_DIRECTORIES: string[];
export const CONSOLE_SETUP: string;
export const EXPO_MOCKS: Record<string, string>;
export const COVERAGE_PATH_IGNORE_PATTERNS: string[];
export const TRANSFORM_PACKAGES: string[];
export const TEST_PATH_IGNORE_PATTERNS: string[];
export const COLLECT_COVERAGE_FROM: string[];
export const IMPORT_META_URL_PLUGIN: string;
export const SCRIPT_TRANSFORM: string;
export function scriptTransform(appRoot: string): Record<string, TransformEntry>;
export const MSW_FETCH_INTERCEPTOR: string;
export function mswFetchMapper(appRoot: string): Record<string, string>;
export const FAKE_TIMERS: { doNotFake: string[] };
export function transformIgnorePattern(packages: string[]): string;
export function createJestConfig(options?: JestPresetOptions): Config;
