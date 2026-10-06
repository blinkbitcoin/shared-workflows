// What `@blinkbitcoin/app-tooling/check-ports` exports: the program's
// command-line entry, `main(argv, io)`, and nothing else. An app's own test
// runs the check in-process through it; the program's helpers stay internal,
// free to change without a breaking release.
export { main } from '../bin/check-ports.mjs';
