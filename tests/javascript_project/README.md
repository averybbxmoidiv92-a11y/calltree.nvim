# calltree.nvim JavaScript test fixture

Mini JavaScript project used by the integration test suite
(`tests/run_javascript_tests.lua`) to verify calltree's end-to-end
analysis against a real `typescript-language-server`.

## Layout

```
javascript_project/
├── package.json     — npm manifest (ES6 module, declares typescript devDep)
├── jsconfig.json    — TS server project config (allows JS, ES modules)
├── utils.js         — helpers: add (arrow fn), greet (fn decl), Calculator (class)
├── index.js         — imports utils via ES6 import, calls each helper
└── README.md        — this file
```

## Setup

Before running the integration test, install the TypeScript dependency
(the `typescript-language-server` requires a local `typescript` install
to function):

```bash
cd tests/javascript_project
npm install
```

This creates `node_modules/` with `typescript`, which
`typescript-language-server` discovers automatically when its `root_dir`
points at this directory.

## What the tests verify

The integration test opens `utils.js`, places the cursor on each
exported symbol (`add`, `greet`, `Calculator.multiply`), and asserts:

1. `current_function` is correctly named (arrow function name extracted
   from the `const` binding, not `nil`).
2. `callers` includes the expected caller from `index.js`
   (`sum` calls `add`, `welcome` calls `greet`, etc.).
3. `external_calls` is populated when analyzing functions in `index.js`
   that call the imported helpers.
4. The JSON output (via `analyze_at_cursor_json`) is well-formed and
   contains the `callers` and `external_calls` arrays.
