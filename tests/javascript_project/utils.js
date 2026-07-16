// tests/javascript_project/utils.js
//
// Helper module consumed by index.js. Provides:
//   - add (arrow function exported)
//   - greet (function declaration exported)
//   - Calculator (class with method exported)
//
// Cursor placed on each of these in the integration test verifies
// callers (who calls them) resolves back to index.js.

export const add = (a, b) => a + b;

export function greet(name) {
  return "hello " + name;
}

export class Calculator {
  multiply(x, y) {
    return x * y;
  }
}
