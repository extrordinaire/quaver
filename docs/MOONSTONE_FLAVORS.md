# Handoff: flavor specialization for Quaver

From the Moonstone side (branch `feat/lua-flavors`, commit `ab59713` in
`../moonstone`). Authoritative spec: `../moonstone/docs/PROJECT_ENVIRONMENT.md`,
section "Flavors: one package for several Luas". This note is what Quaver needs
from it. Nothing in `quaver/` was changed.

## What Moonstone now provides

- **Flavor**: language (`lua51`…`lua55`, `luajit`, `luau`) + host os + arch.
  Id format: `lua54-aarch64-macos`, `luajit-x86_64-linux`. Not the C ABI.
- **`MOONSTONE_TARGET`**: exported by `moon exec` / `moon run` from
  `.moonstone/env/env.toml` `[target]`, **unless the caller already set it**.
  `MOONSTONE_TARGET=lua51-x86_64-linux moon run build` = build for 5.1.
- **`require("moonstone.target")`**: constant table
  `{ id, family, level (51..55; luajit/luau = 51), os, arch, runtime = { name, version, abi } }`.
- **`require("moonstone.project")`**: constant table
  `{ name, version, kind, description?, dependencies = { {name, version, role}, ... } }` (sorted by name).
- **`require("moonstone.variants")`**: the file-selection rule in Lua:
  `parse(file_name)`, `match(variant, flavor)`, `select(candidates, has_base, flavor)`,
  `suffixes(flavor)`, `resolve(module_name, flavor, path)`, `install()`.
  Same rule as the linker's `src/core/platform/flavor.zig`; shared cases in
  `../moonstone/tests/lua/variants_spec.lua`.
- **Variant files**: `lexer@lua54.lua`, `lexer@luajit.lua`, `fs@lua51@windows.lua`.
  Tags in order language, os, arch; at most one per dimension. The winner must
  dominate every other match on every dimension, otherwise it's an error.
  `@lua51` matches LuaJIT (less specifically than `@luajit`); Luau never
  inherits `@lua51`. Dependencies arrive already resolved: the env holds
  `lexer.lua`. A project's own `src/` still holds the tagged files.

## What Quaver should do

1. **Pick the target**: read `MOONSTONE_TARGET`. If it equals the env's own
   `[target] id`, use `require("moonstone.target")` as is. Otherwise build the
   table from the id (`family`, `level`, `os`, `arch`) and treat
   `target.runtime` as unknown. It describes the host interpreter and must not
   be folded for a different flavor.
2. **Select files** in the project's own sources with
   `moonstone.variants` (`parse` + `select`, or `resolve` against a path).
   Don't reimplement the rule. Emit the chosen file under the untagged name and
   drop the other variants from the bundle. Treat `"ambiguous"` as a build error.
3. **Fold constants** only when the module is bound as
   `local x = require("moonstone.target")` (or `"moonstone.project"`,
   or `require("moonstone").target`) and `x` is never reassigned, nor passed
   anywhere that could mutate it. Field reads (`x.level`, `x.family`, `x.os`, ...)
   become literals.
4. **Dead-branch elimination**: after folding, `if` / `elseif` arms whose
   condition is a constant comparison can be removed (`x.level >= 53`,
   `x.family == "luajit"`, `x.os ~= "windows"`). Also worth folding:
   `_VERSION` and `jit ~= nil` / `type(jit)` when the target is known.
   `optimizer.lua` currently says statement deletion needs scope/effect
   analysis first. This needs that AST.
5. **Don't try to parse the union**: code that some flavor can't lex
   (`<const>`, `<close>`, `//`, `&`, `goto` on 5.1, Luau type annotations)
   belongs in variant files, not dead branches. Quaver's parser only ever
   needs the target flavor's grammar for the files it selected.

## Open on the Moonstone side (not blocking)

- `--moon:build <expr>` header pragma for conditions tags can't express.
- `moon test --flavors ...` matrix; recording flavor in `moonstone.lock`.

## Quaver implementation status

Implemented in `quaver.flavors`, `quaver.ast`, and `quaver.specialize`:

- `MOONSTONE_TARGET` takes precedence over a configured flavor. Matching the
  generated host id preserves its target table; cross-target contexts construct
  language/os/arch fields and mark runtime unknown.
- The Ballad adapter delegates inventory selection to the canonical
  `moonstone.variants.parse/select` before parsing. The CLI uses its `resolve`
  API. Ambiguity is an error. Moonstone's implementation is not copied.
- A statement/expression AST parses the selected source. Top-level, single-name
  metadata bindings can fold primitive field reads. Reassignment, shadowing,
  root/child-table escape, dynamic indexing, and duplicate imports conservatively
  disqualify a binding. Nested read-only closures are supported.
- Constant conditions remove unreachable arms; chosen bodies retain a `do` scope.
  Calls and arithmetic are not evaluated by the optimizer. Integer literals are
  folded only within the exact shared numeric range.
- Host runtime data is never bundled as the cross target. Generated Moonstone
  metadata modules remain runtime externals. Cross-target runtime field reads
  stay intact.
- `_VERSION` and `jit` folding requires `assume_runtime_globals=true`, an explicit
  assertion that runtime globals retain their standard identity. Local shadowing
  and direct writes still prevent these folds.

Current frontend boundary: the common Lua statement/expression grammar exercised by Valua, with language-level gates
for operators, goto/labels, and local attributes. Complete grammar coverage for every supported Moonstone flavor is not claimed. It parses selected files only.
Luau's type annotations and other extensions are not implemented: selecting a
file with those extensions fails explicitly. They are not stripped or parsed as
another flavor. General binding resolution and mutation/effect inference remain
conservative rather than attempting to prove arbitrary calls safe.

`tests/flavors.lua` imports the canonical module from the adjacent Moonstone
branch and tests the handoff contract. `examples/flavors.partiture.lua` demonstrates
selection and specialization together using that source module until Moonstone
releases the generated-module support. The existing Moonstone shared variant
suite is also run unchanged. Quaver does not modify or push the Moonstone branch.
