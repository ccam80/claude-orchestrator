# Phase 1: Test File Creation

## Wave 1.1: Create Module and Test

### Task T1.1a — Create greet module (S)

**Files to create:**
- `src/hello.js` — exports a `greet(name)` function

**Specification:**
- The function takes a single string parameter `name`
- Returns the string `"Hello, {name}!"` where `{name}` is the parameter value
- Export as a named export: `module.exports = { greet }`

**Acceptance criteria:**
- `greet("World")` returns `"Hello, World!"`
- `greet("")` returns `"Hello, !"`

### Task T1.1b — Create test file (S)

**Files to create:**
- `test/hello.test.js` — tests for the greet function

**Specification:**
- Uses Node.js built-in test runner (`node:test` and `node:assert`)
- Tests:
  1. `greet("World")` returns exactly `"Hello, World!"`
  2. `greet("Claude")` returns exactly `"Hello, Claude!"`
  3. `greet("")` returns exactly `"Hello, !"`

**Acceptance criteria:**
- All three tests pass when run with `node --test test/hello.test.js`
