# Hydronium SSR experiment

This small server-rendered page compares root-facade imports with narrow imports,
then tests Quaver compaction and two independently analyzable helper modules.
It uses real Hydronium rendering, ordinary module files, and the host Lua loader.
No production site or framework sources are changed.

Run from the Quaver repository with Hydronium 0.7.0 checked out separately:

```sh
moon exec -- lua examples/hydronium/verify.lua /path/to/hydronium
luajit examples/hydronium/verify.lua /path/to/hydronium
```

The measured checkout is `moonstone-sh/hydronium` commit
`d20725c` (the 0.7.0 release merge). The experiment reads the portable source
fallbacks from `core/src`, `dom/src`, and `router/src`. It does not perform a
Moonstone flavor projection or test browser Lua engines.

## Measurements

Both Lua 5.4 and LuaJIT 2.1 produced identical results:

| Imports / transformation | Loaded framework modules | Lua source bytes, including page |
| --- | ---: | ---: |
| Root `hydronium` facade | 44 | 324,774 |
| Root facade, compacted | 44 | 166,502 |
| Root facade, compacted + helper mangling | 44 | 165,384 |
| Narrow element + SSR imports | 25 | 181,297 |
| Narrow imports, compacted | 25 | 81,947 |
| Narrow imports, compacted + helper mangling | 25 | 80,829 |

Narrow imports account for the module reduction; that is a Hydronium API choice,
not Quaver tree-shaking. Compaction preserves the supplied module inventory.
The final variant strictly analyzes and mangles `hydronium_dom.style` and
`hydronium_dom.server.json` independently, then emits them as ordinary module
files beside the other compacted modules. It saves another 1,118 bytes.

These totals count the source of modules observed as loaded by this fixture,
not a deployable closure or browser payload. Every variant emits the complete
supplied inventory; runtime observations never authorize deleting modules.
Unexercised lazy paths remain present. JavaScript, CSS, fonts, WASM, native server
size, and network transfer are outside these totals.

## Verification and blockers

Each variant runs in a separate process. The checks compare rendered HTML,
component composition, text and attribute escaping, inline styles, repeated
rendering, JSON round-trips (including Unicode and escaped characters), malformed
JSON rejection, and style serialization. Root and narrow imports produce the
same output. Conservative builds preserve every supplied module byte-for-byte
and withhold the requested mangle pass.

On the released 0.7.0 checkout, reflective compatibility and integration paths
block whole-site Strict builds. The follow-up below measures the capability split
under review, rather than changing compiler assumptions to bypass those paths.

## Renderer-isolation follow-up

When the supplied checkout contains `hydronium_dom.server.renderer`, the runner
also tests that explicit plain-renderer entrypoint and compares its output with
the site-facing entrypoint. This capability split is under review in
[Hydronium #29](https://github.com/moonstone-sh/hydronium/pull/29).
The plain renderer excludes the lazy Meteorite adapter and Vite/manifest loading.
With explicit SVG lookup declarations, Quaver main now proves its Strict closure.
This requires unreleased Quaver changes, including the member-name scanner and
self-`__index` export proof; registry version 0.1.2 is not sufficient.

| Plain renderer artifact | Bytes |
| --- | ---: |
| Original loaded source + page | 154,346 |
| Compacted loaded source + page | 74,230 |
| Compacted + JSON/style mangling | 73,112 |
| Strict mangled module files | 56,269 |
| Strict standalone bundle | 57,454 |

The Strict artifacts retain 25 modules, including the page and an explicit
verification entry. They are emitted from the statically proved dependency graph,
not from observed loads. Both files and bundle execute in isolated processes on
Lua 5.4 and LuaJIT and match the original HTML, SVG, JSON, styles, and repeated
renders. The bundle is approximately 62.8% smaller than the original fixture's
loaded source, with the extra verification entry included. No consumer export
profiles are supplied: unused features inside retained modules remain present.
Root/site-facing imports still reject reflective compilation or Meteorite paths.
