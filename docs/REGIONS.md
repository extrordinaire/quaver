# Static regions beside a dynamic host

Quaver can optimize separately owned static artifacts while preserving a dynamic host. It does not infer isolation from a module prefix, a purity flag, or a plugin declaration. Static artifacts have their own source inventories and private module caches; only their entry value is published.

This is explicit multi-artifact composition, not automatic partitioning of an arbitrary shared Lua graph. An ordinary runtime boundary still preserves its whole shared inventory. Putting dynamic and static code into one loader scope does not gain an optimization proof.

## API

```lua
local compiler = require('quaver.regions')
local options = {
  host = {
    entry = 'app',
    modules = hostSources,
    boundaries = {
      app = {kind='runtime',reason='Plugins are discovered at runtime'},
    },
  },
  regions = {
    validator = {
      entry = 'app',
      modules = validatorSources,
      minify = {level="safe"},
      facades = {
        ['valua.init'] = {
          exports = {'object','pipe','string','min_length','optional','number','safe_parse'},
        },
      },
    },
  },
}
local result = compiler.build(options)
local files = compiler.files(result, options)
```

`result.host` is preserved in Conservative mode. `result.regions.validator` is a Strict build with the existing export and initializer proofs. `files` maps relative output paths to bytes; writing is separate from compilation. The API does not read files or start processes. Configurations are not mutated.

All inventories must be complete. Region dependencies must resolve inside that region's inventory; host sources are never searched as a fallback. Region callbacks, external allowlists, nested regions, and runtime boundaries fail rather than weakening the proof. If flavor specialization leaves a runtime metadata import, the emitted graph fails the closed-artifact check. Select variants with Moonstone's canonical selector before supplying inventories.

The host calls the published entry through an ordinary require:

```lua
local validate = require('__quaver_regions.validator')
return function(plugin_name,input)
  local plugin = require(plugin_name)
  return validate(plugin(input))
end
```

The output directory belongs on `package.path`. Static region internals are inside the artifact, not loose module files or host `package.loaded` entries. Separate regions can use identical internal module names without sharing their loading state. Dynamic plugins and returned entry functions still execute normally; no runtime effects are removed from those functions.

## Ballad

The maintained [regional example](../examples/regions.partiture.lua) composes a dynamic plugin host and the real Valua validator:

```sh
moon exec -- ballad play examples/regions.partiture.lua
moon exec -- lua -e 'package.path="dist/regions/?.lua;"..package.path; assert(require("app")("plugin",{name="Lua"}).success)'
```

`quaver.compose` accepts declared asset sets. Assign each scope its input indexes explicitly:

```lua
local output = quaver.compose(hostSources, {
  depends_on = {valuaSources,validatorSource},
  host = {entry='app',inputs={1}},
  regions = {
    validator = {
      entry='app',inputs={2,3},minify={level="safe"},
      facades={['valua.init']={exports={'object','pipe','string','min_length','optional','number','safe_parse'}}},
    },
  },
})
p.sink.directory(output,{out='dist/regions',incremental=true})
```

Indexes refer to the primary input followed by declared dependencies. Inputs can be reused across independently compiled regions, but every declared input must be assigned to a scope. Duplicate module ids within one scope fail. Transformed asset content takes precedence over its original source file, as in the ordinary optimizer adapter.

The example emits:

```text
dist/regions/
  app.lua                           # host, unchanged
  plugin.lua                        # host, unchanged
  __quaver_regions/
    validator.lua                   # private static artifact
    validator.contract.lua
  quaver-contract.lua               # host provenance
  quaver-regions.lua                # entries, paths, sizes, bundle hashes
  quaver-report.txt
```

Valua retains 15 modules and removes 63 in this example. Each static scope chooses its own minification level (`none`, `safe`, `compact`, or `mangle`). The host remains unminified. Each scope gets its own contract report; Ballad records BLAKE3 source, output, and artifact hashes. Changing a host plugin leaves an unchanged static artifact untouched by the incremental directory sink. The compiler transform remains non-cacheable until compiler source fingerprints become declared inputs.

## CLI

A configuration returning `{host=...,regions=...}` uses this same composition API:

```sh
moon exec -- lua src/main.lua build regional.config.lua dist/regions
```

The output argument is a directory. Provide module maps in the configuration; regional CLI builds do not search source roots lazily. The CLI emits deterministic reports but does not supply a hash implementation, so its reports explicitly record hashes as unavailable. Ballad is the integration for declared filesystem inventories and BLAKE3 provenance.

`require('quaver.schemas').create(valua).region` validates the build declaration shape separately from semantic analysis. The compiler still establishes the actual proofs.

## Diagnostics and limits

- `QV301`: invalid regional configuration, scope assignment, or output format.
- `QV302`: a static artifact crosses an unverified runtime boundary.
- `QV303`: output ownership or path collision.
- Existing Strict diagnostics include the affected region name, compiler stage, and source location. Failures also retain reports from completed scopes; see [observability](OBSERVABILITY.md).

`__quaver_regions` and Quaver's report names are reserved in the host output. Region names cannot contain dots, slashes, or traversal components.

The private loader is an artifact contract, not a security sandbox. It does not prevent debug introspection, filesystem access, shared globals, or hostile code from probing functions. Do not treat an arbitrary reflective host as observationally equivalent to a shared-module application after bundling. Programs that rely on those interactions must retain their shared inventory or use a genuine process/security boundary. Quaver does not silently convert existing shared modules into isolated artifacts or wire their entry points for you.
