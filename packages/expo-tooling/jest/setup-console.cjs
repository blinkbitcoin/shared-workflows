// A Jest `setupFilesAfterEnv` entry: the silent-tests guard, and nothing else.
// createJestConfig appends it to both projects, after the app's own setup, so
// its `afterEach` is the last to run.
'use strict';

require('./console.cjs').installConsoleGuard();
