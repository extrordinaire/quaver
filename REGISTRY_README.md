# Quaver

Quaver provides independent Lua tree-shaking, minification, and optimization passes, with a strict Ballad adapter for building smaller projects.

For a local checkout, add Quaver to a Moonstone project and sync it:

```sh
moon add path:../quaver
moon sync
moon exec -- lua -e 'print(require("quaver.minifier").minify("return 42"))'
```

The core APIs are `require('quaver.tree_shaker').shake`, `require('quaver.minifier').minify`, and `require('quaver.optimizer').optimize`. Each can be imported independently. `require('quaver.build').build` composes them. `require('quaver.ballad')` exposes the Ballad optimization transform.

Start with the maintained Valua example in [the repository README](README.md). Its Strict profile is checked against initializer effects and consumer reads, then emits `validate.lua`, `quaver-report.txt`, and `quaver-contract.lua`. Conservative mode preserves a complete source inventory. Explicit runtime boundaries preserve dynamic code. [Regional composition](docs/REGIONS.md) optimizes separately owned static artifacts beside a preserved dynamic host. See [the contract documentation](docs/CONTRACTS.md). Optional Moonstone flavor specialization uses an AST and the canonical variant selector; see the flavor contract in the repository docs.

Ballad creates the versioned source package and descriptor in `dist/registry/quaver/`. Each GitHub `v*` release includes those files as release assets. The workflow submits the package to the Moonstone registry only when the repository's `MOONSTONE_TOKEN` secret is configured.
