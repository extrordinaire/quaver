# Optimization contracts

Strictness increases what Quaver can prove, not what it may assume.

## Conservative

`mode='conservative'` is the default. Supply a complete `modules` inventory (or declared Ballad assets). Quaver retains every source byte and every supplied module, including dynamic or reflective code. Requests for export selection, specialization, or minification are withheld with notes. A lazy loader cannot enumerate dynamic dependencies, so using one without an inventory produces `QV203`.

Emit ordinary module files. Conservative builds cannot use the private bundle loader, whose module cache and cycle behavior differ from Lua's loader. Preserve the application's entry invocation, module layout, external dependencies, and runtime search path when deploying those files. Quaver does not package arbitrary non-Lua resources.

## Strict

```lua
local result = require('quaver.build').build({
  mode = 'strict',
  entry = 'app',
  modules = sources,
  facades = {lib = {exports = {'used'}}},
  minify = true,
})
```

The initial verifier accepts a deliberately small model: literal dependency edges, locally constructed exports, static construction of private tables, and effect-free initializer closures made from literals, functions, tables, locals, and verified imports. Verified table dependencies are also checked against mutations and escapes through other retained importers, including facade aliases. A facade profile specifies the intended public surface; Quaver verifies actual consumer reads against it. Aliases selected by the facade are retained automatically.

A locally constructed exports table may also be its instances' metatable, the usual Lua class shape:

```lua
local ValidationError = {}
ValidationError.__index = ValidationError

function ValidationError.create(issues)
  return setmetatable({ issues = issues }, ValidationError)
end

return ValidationError
```

The table may appear as the value of a top-level `T.__index = T` and as the second argument of `setmetatable(value, T)`, where `setmetatable` is the unshadowed global. Neither adds fields beyond `__index`: instances read through the table, and their own writes stay on the instance. Every other escape still fails with `QV104`, including `setmetatable(T, mt)` (a metatable on the exports themselves), aliases (`local U = T`), passing `T` to other functions, storing it in other tables, and `__index` assignments inside functions. Facade export selection does not apply to these modules, so no method is ever removed from a class.

`pure=true` grants no permission. Global writes, unknown initializer calls, cyclic initializer proofs, closing variables, unknown external initializer effects, escaping facade bindings, shadowed imports, dynamic indexing, omitted export reads, and deferred export mutation fail with diagnostics. A valid program can fail this narrow model; that is a limitation of the proof system, not evidence of bad architecture.

For example:

```text
quaver: QV104
Cannot prove that module exports are immutable.

  app.lua:7:24

Strict optimization requires exports to remain structurally stable.

Suggestion: Move dynamic registration behind an explicit runtime boundary.
```

Errors are structured Lua values with `code`, `severity`, `path`, `line`, `column`, `message`, `explanation`, and `suggestion`. Use `tostring(error)` for their human-readable form. The CLI does this automatically and exits unsuccessfully.

| Code | Meaning |
| --- | --- |
| QV001 | Invalid contract declaration |
| QV101 | Unsupported syntax for analysis |
| QV102 | Unanalyzable module loading |
| QV103 | Missing source dependency |
| QV104 | Unproven export stability or consumer access |
| QV105 | Unproven initializer effects |
| QV106 | Cyclic initializer proof |
| QV107 | Consumer reads an omitted export |
| QV108 | Strict build requested assumed runtime globals |
| QV110 | Program requires ordinary module-file emission |
| QV111 | Reflective runtime access prevents local mangling |
| QV201–QV202 | Preservation / withheld optimization notes |
| QV203 | Missing complete inventory for dynamic preservation |
| QV900 | Unexpected compiler or adapter stage failure |

## Dynamic boundaries

```lua
boundaries = {
  plugins = {
    kind = 'runtime',
    reason = 'Plugins register themselves after discovery',
  },
}
```

A runtime boundary preserves dynamic behavior; it does not certify purity. In this first implementation, **any boundary preserves the entire supplied inventory** and requires ordinary file output. Run `moon exec -- ballad play examples/dynamic.partiture.lua` for a working module-file example. For separately owned static artifacts beside a dynamic host, use [regional composition](REGIONS.md). Arbitrary shared-graph partitioning remains unsupported. This cautious fallback lets registries, dependency injection, and runtime discovery remain legitimate designs without silently weakening Strict mode.

## Artifact output

Ballad and the CLI default to `format='files'`. The CLI's output argument is then a directory, and its directory creation currently requires a POSIX shell. Ballad provides the portable filesystem integration. For a closed artifact that accepts Quaver's private-loader contract, explicitly set `mode='strict', format='bundle'`; the output argument becomes a file. Bundles have a private module cache, explicitly reject circular initialization at runtime, and do not implement arbitrary host-loader behavior.

Minification levels are independent of Conservative/Strict correctness modes:

| Level | Behavior |
| --- | --- |
| `none` | Disable the minifier; preserve its input bytes |
| `safe` | Remove comments and redundant whitespace while preserving source line counts |
| `compact` | Also remove unnecessary line breaks |
| `mangle` | Compact whitespace and shorten lexically resolved locals, parameters, and upvalues |

```lua
minify = {level='compact'}
```

Builds default to `none`. `minify=true` remains shorthand for `safe`; `false` means `none`. Invalid options produce `QV001`. Mangling uses declaration and reference spans from the Lua AST, with separate identities for shadowed bindings and captured upvalues. Generated names never collide with original identifiers and are not reused across bindings. Globals, public property names, labels, literal spelling, implicit method `self`, and `_ENV` semantics are preserved. Already-short locals are never lengthened. Inlining and general dead-statement elimination remain optimizer work, not minification levels.

Conservative mode and preserved runtime boundaries withhold `safe`, `compact`, and `mangle`, recording requested and applied levels separately. An explicit `compact` request in a Strict artifact changes debugging line positions, not its semantic proof policy. Safe and compact preserve all token spellings; mangle changes only proven local identifier tokens. Every level preserves literal bytes and public identifiers. `none` disables only minification; facade selection and other enabled compiler passes can still change source formatting.

Known reflective access (`debug`, `package`, `_G`, environment inspection, dynamic loaders, and direct reflective-module imports) is rejected by mangle with `QV111`. Local variables merely named `debug` or `require` remain ordinary lexical bindings. Mangling is not a sandbox: programs that observe local names through externally supplied reflection callbacks must use another level. Names in debug metadata and error messages can change; source maps and reverse-name maps are not emitted yet.

Standalone `minifier.minify(source)` retains its historical `compact` default. Prefer explicit `{level='safe'}` or `{level='compact'}` for new code. Legacy `{preserve_lines=true}` and `{preserve_lines=false}` remain supported by the standalone API; they cannot be combined with named levels. Strict build line preservation applies to the minifier's input, not to original locations across facade selection or bundling. No minifier promises to preserve reflective source text or debug columns.

For the maintained Valua example, after identical tree-shaking:

| Level | Module bytes | Bundle bytes, including loader |
| --- | ---: | ---: |
| `none` | 15,040 | 16,534 |
| `safe` | 8,264 | 9,758 |
| `compact` | 7,895 | 9,389 |
| `mangle` | 5,980 | 7,474 |

Reports include normalized requested/applied levels and the module byte count before minification. The private bundle loader is emitted separately and is not compacted by these module-level settings.

Moonstone variant selection remains canonical through `moonstone.variants`. Metadata specialization relies on Moonstone's documented metadata contract. Cross targets do not inherit host runtime identity. Strict builds reject `assume_runtime_globals=true`; the low-level optimizer still exposes this opt-in assumption for callers with a separate runtime contract.

## Reports and validation

Ballad emits `quaver-report.txt` and `quaver-contract.lua`. The latter is sorted, data-only Lua containing mode, export profiles, boundary reasons, initializer proof results, selected modules, and BLAKE3 hashes of input/output source bytes. Machine-specific source locations are excluded. Repeated identical builds produce identical reports.

Stage statistics and retention/removal explanations are included. [Run traces and partial failure reports](OBSERVABILITY.md) are separate from reproducible contracts. These records support comparison and provenance checks; they are not a formal proof certificate or a security attestation. Compiler version is recorded, but source-level compiler fingerprints and cache integration remain unfinished. The transform therefore stays non-cacheable; the directory sink can still avoid rewriting unchanged output.

`require('quaver.schemas').create(valua)` exposes optional Valua schemas for contract declarations. Injecting Valua keeps all three compiler passes independently usable. Shape validation catches invalid declarations; only AST analysis can establish initializer and export properties.
