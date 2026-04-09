# Test Baseline

- **Timestamp**: 2026-04-09T17:30:00Z
- **Phase**: Phase 1: Test File Creation
- **Command**: `node --test test/hello.test.js`
- **Result**: Test files do not exist yet

## Status

The project currently has no test files. The spec defines that Phase 1 will create:
- `src/hello.js` — a module exporting a `greet(name)` function
- `test/hello.test.js` — tests for the greet function using Node.js built-in test runner

The test command `node --test test/hello.test.js` is specified in the plan but cannot be executed until Phase 1 implementation creates the necessary files.

## Pre-existing Failures

None — no tests currently exist to fail.

## Acceptance Criteria for Phase 1

Once Phase 1 is implemented, the test must produce:
- 3/3 tests passing
- 0 failures
- 0 errors

Test specifications:
1. `greet("World")` returns `"Hello, World!"`
2. `greet("Claude")` returns `"Hello, Claude!"`
3. `greet("")` returns `"Hello, !"`
