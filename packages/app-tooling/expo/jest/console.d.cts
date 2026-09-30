export type GuardedConsoleMethod = 'error' | 'warn';

export type ConsoleMatcher = string | RegExp;

export interface ConsoleCall {
  method: GuardedConsoleMethod;
  message: string;
}

export interface ConsoleLike {
  error: (...args: unknown[]) => void;
  warn: (...args: unknown[]) => void;
}

export interface ConsoleRecorder {
  /** Install the recording stubs. Safe to call once per test. */
  start: () => void;
  /** Restore the real methods and return the calls no allowance covered. */
  stop: () => ConsoleCall[];
  /** Permit matching output on `method` for the current test only. */
  allow: (method: GuardedConsoleMethod, matcher?: ConsoleMatcher) => void;
}

export interface LifecycleHooks {
  beforeEach: (fn: () => void) => void;
  afterEach: (fn: () => void) => void;
}

export declare const GUARDED_METHODS: readonly GuardedConsoleMethod[];
export declare function formatCall(call: ConsoleCall): string;
export declare function matches(matcher: ConsoleMatcher | undefined, message: string): boolean;
export declare function createConsoleRecorder(target?: ConsoleLike): ConsoleRecorder;
export declare function formatFailure(unexpected: readonly ConsoleCall[]): string;
export declare function allowConsole(method: GuardedConsoleMethod, matcher?: ConsoleMatcher): void;
export declare function assertSilent(target: ConsoleRecorder): void;
export declare function installConsoleGuard(hooks?: LifecycleHooks): void;
