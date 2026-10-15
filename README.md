# Quaver

Quaver builds smaller Lua programs from an explicit module graph. Its first integration is Valua: keep the schema primitives a consumer needs, remove the remaining facade exports and unreachable modules, then minify while preserving string literals and public identifiers.

## Install

Add the published package to your Moonstone project:

```sh
moon add moonstone/quaver
moon exec -- lua -e 'print((require("quaver.minifier").minify("return 42")))'
```

The command prints `return 42`. For a fresh project, run `moon init . --name my-app --kind script --interpreter lua@5.4` first. `moon add` synchronizes the project environment automatically.

For Ballad integration, also add Ballad as a tool:

```sh
moon add --tool moonstone/ballad
moon exec -- ballad play partiture.lua
```

See [the Ballad guide](https://ballad.moonstone.sh/docs/quaver) for a complete recipe.

Three independent entry points expose its passes:

```lua
local shaker = require('quaver.tree_shaker') -- shaker.shake(options)
local minifier = require('quaver.minifier')  -- minifier.minify(source)
local optimizer = require('quaver.optimizer') -- optimizer.optimize(source, context)
```

`require('quaver')` is a thin, shakeable facade. The minifier does not import the tree-shaker or optimizer. The tree-shaker does not import the minifier. The optimizer imports neither of the other passes. `require('quaver.build').build(options)` composes the three. The CLI, bundle emitter, and Ballad adapter are separate modules. Core passes use only the Lua standard library; the Ballad adapter needs Ballad.

## Run the Valua example

From this workspace's `quaver/` directory:

```sh
moon sync
moon run test
moon run example
```

The declarative partiture at `examples/valua.partiture.lua` declares both source inventories, an optimization node, and an incremental directory sink. It creates:

```text
dist/valua/
  validate.lua
  quaver-report.txt
  quaver-contract.lua
```

```lua
local validate = assert(loadfile('dist/valua/validate.lua'))()
local result = validate({name='Lua',age=30})
assert(result.success)
```

The strict example configuration explicitly requests a bundle output file:

```sh
moon exec -- lua src/main.lua build examples/valua.config.lua /tmp/validate.lua
```

The CLI roots are relative to the working directory. Literal `require` dependencies are resolved as `module.lua` then `module/init.lua`. The API accepts an in-memory `modules` map and does no filesystem access; strict callers can instead supply a `load(id)` callback. Conservative mode requires a complete inventory.

## Ballad transform

```lua
local plugin = p:use(require('quaver.ballad'))
local optimized = plugin.optimize(sources, {
  entry = 'app',
  mode = 'strict',
  format = 'bundle',
  minify = {level="safe"},
  depends_on = {consumerSources}, -- a second declared AssetSet input
  name = 'validate.lua',
  facades = {
    ['valua.init'] = {
      exports = {'object','pipe','string','min_length','optional','number','safe_parse'},
    },
  },
})
p.sink.directory(optimized, {out='dist/valua',incremental=true})
```

The adapter consumes declared `.lua` assets, preserves transformed `asset.content` in preference to reading its original file, and emits module files by default, or an explicitly requested strict bundle, plus text and data reports. The transform currently reruns so local compiler edits cannot reuse stale output; the incremental sink preserves unchanged output files. Enabling transform caching needs a declared compiler fingerprint. Module ids preserve explicit `init` names: Valua's `valua.lua` forwards to the facade at `valua.init`.

See the [Hydronium SSR experiment](examples/hydronium/README.md) for measured
root versus narrow imports, compaction, helper mangling, and current Strict blockers.

## Safety and current scope

Conservative mode is the default: it preserves every supplied module byte-for-byte. Strict mode requires literal dependency edges, verifies stable exports and initializer effects, and checks that actual facade consumers use only the selected exports. `pure=true` cannot substitute for a proof. Unproven contracts produce structured diagnostics with locations and repair suggestions.

Dynamic behavior can be declared through runtime boundaries. Boundaries preserve their shared inventory rather than weakening the verifier. [Regional composition](docs/REGIONS.md) can optimize separately owned static artifacts beside a dynamic host. Ordinary module files are the default output; a strict private-loader bundle requires `format='bundle'`. Minification supports `none`, `safe`, `compact`, and `mangle`; `true` still means `safe`. Safe preserves line counts; compact removes unnecessary line breaks. Mangle also shortens lexically resolved locals while preserving globals, public fields, and literal bytes. Known reflective access is diagnosed. Standalone compact minification remains independent.

See [compiler observability](docs/OBSERVABILITY.md) for deterministic stage statistics, decision reasons, optional CPU traces, and saved failure reports.

See [optimization contracts](docs/CONTRACTS.md) for modes, diagnostics, boundary limitations, optional Valua schemas, and the reproducible Ballad contract report. These checks are not a security sandbox or a full Lua semantic proof.

## Development

Run the suite with both supported interpreters and exercise the real Ballad
example and release package:

```sh
moon sync
moon run test
moon run test --interpreter luajit@2.1
moon run example
moon run package
```

The Valua proof tests and example read the adjacent `valua/src` tree. Until a
Valua release includes its local-helper fix, CI pins Valua commit
`253601b7e8841458d62efe4bcdd1f7441a56887b` from
`moonstone-sh/valua` (`fix/json-schema-local-helper`). The fix prevents JSON
Schema conversion from leaking a helper into the global namespace.

The `v*` release workflow validates both interpreters, runs the Valua Ballad
example, and builds the source package twice to check that its archive bytes are
reproducible. It attaches the Ballad package descriptor, README, publish script,
and source archive to the GitHub release. Moonstone registry submission runs
only when the repository has a `MOONSTONE_TOKEN` secret configured.

- `src/quaver.lua`: public facade.
- `src/quaver/{tree_shaker,minifier,optimizer}.lua`: independent passes.
- `src/quaver/{lexer,literal,facade}.lua`: shared lexical analysis and facade selection.
- `src/quaver/build.lua`: orchestration of the three independent passes.
- `src/quaver/{flavors,ast,specialize}.lua`: Moonstone integration and conservative AST specialization.
- `src/quaver/bundle.lua`: standalone module registry emitter.
- `src/quaver/regions.lua`: independent inventories, closed artifacts, and regional reports.
- `src/quaver/ballad.lua`: Ballad optimization and regional composition adapters.
- `src/main.lua`: CLI.
- `tests/run.lua`: execution equivalence, lexical boundaries, conservative rejection, deterministic output, and Quaver self-hosting.

The test inventory helper uses POSIX `find`; the core modules have no shell dependency. Generated output, the Moonstone environment, and Ballad caches are excluded from source control. CI checks out Moonstone's canonical `moonstone.variants` implementation at a pinned commit so flavor tests exercise the real selector.

## Moonstone flavor builds

When Moonstone's generated modules are available, `MOONSTONE_TARGET` selects the
build flavor. The Ballad adapter chooses tagged source files with
`moonstone.variants` before parsing. The CLI resolves variants with the same API.
A host-matching target keeps its runtime identity; a cross target never folds
host runtime data. The generated Moonstone metadata modules stay runtime
externals, so a flavor bundle that still imports them runs in a Moonstone
environment.

For API consumers, `require('quaver.flavors').context(options)` creates the
context; `flavors.select(files, context)` selects an in-memory filename/source
inventory. Pass the resulting module map and `target_context=context` to `require('quaver.build').build`. The minifier and tree-shaker remain independent of Moonstone.

The AST pass folds primitive reads of unmodified, unshadowed, unescaped metadata
bindings and removes branches with proven constant conditions. It preserves the
chosen branch's local scope. Newer syntax belongs in a variant, even if its branch
would be dead. Full Luau syntax is not supported yet. Runtime global assumptions
are available only through the low-level optimizer; Strict builds reject them.

See [the flavor handoff and implementation notes](docs/MOONSTONE_FLAVORS.md).
To exercise the Moonstone flavor example in this workspace:

```sh
moon exec -- ballad play examples/flavors.partiture.lua
```

This development example imports Moonstone's canonical module directly from the
adjacent repository; production builds use the module generated by `moon sync`.
