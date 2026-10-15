# Quaver development

Keep tree-shaker, minifier, and optimizer independently importable. The public facade must remain eligible for Quaver's own export selection. Shared lexical internals must not depend on the optimizer, CLI, or Ballad adapter.

Never accept declared purity as evidence. Facade elimination needs an explicit consumer export profile and a verified initializer closure. Conservative mode preserves source inventory; Strict mode rejects unproven contracts. Runtime boundaries grant no optimization assumptions. Regional composition requires separate complete inventories and private artifacts; never infer isolation from a module namespace. Preserve string spelling and public identifiers. Local identifiers may change only at the explicit mangle level, using verified lexical binding spans. Reject unsupported dynamic loading; do not silently omit dependencies. Algebraic rewrites and local renaming need scope/effect analysis and runtime differential tests before implementation.

Use Moonstone to manage the environment. Run `moon run test`, test LuaJIT too, and run the real Ballad Valua example after pipeline changes. Do not commit `dist/`, `.ballad/`, or `.moonstone/`.
