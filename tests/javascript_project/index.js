// tests/javascript_project/index.js
//
// Main module — imports helpers from utils.js via ES6 import.
// Each top-level function below calls one or more imported helpers,
// giving the integration test realistic cross-file caller/external-call
// scenarios to verify.

import { add, greet, Calculator } from './utils';

// Arrow function assigned to const — calls add (imported).
const sum = (a, b) => {
  return add(a, b);
};

// Function declaration — calls greet (imported).
function welcome(name) {
  return greet(name);
}

// Class method — instantiates Calculator and calls its multiply method.
class App {
  run(x, y) {
    const calc = new Calculator();
    return calc.multiply(x, y);
  }
}

// Invoke the top-level functions so the module has side effects
// (also gives callers analysis something to find).
console.log(sum(1, 2));
console.log(welcome("world"));
console.log(new App().run(3, 4));
