const test = require('node:test');
const assert = require('node:assert');
const { greet } = require('../src/hello.js');

test('greet("World") returns "Hello, World!"', () => {
  assert.strictEqual(greet('World'), 'Hello, World!');
});

test('greet("Claude") returns "Hello, Claude!"', () => {
  assert.strictEqual(greet('Claude'), 'Hello, Claude!');
});

test('greet("") returns "Hello, !"', () => {
  assert.strictEqual(greet(''), 'Hello, !');
});
