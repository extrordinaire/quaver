# Compiler stages, traces, and failures

`quaver.build.build` records compilation stages automatically. These records do not execute the input program. They describe the compiler's work and remain separate from Valua's runtime validation issues.

## Deterministic records

`result.report.stages` contains ordered records for validation, source loading when needed, dependency scanning, export and initializer proofs, consumer proofs, export selection, specialization, local mangling, whitespace minification, and bundle emission. Only passes that actually run are recorded. Disabled or withheld minification is recorded as skipped, with a reason.

A stage record includes its status and logical module identity, plus the measurements available for that pass:

```lua
{
  stage='mangle',
  module='valua.schemas.string',
  status='success',
  input_bytes=729,
  output_bytes=500, -- illustrative
  counters={renamed_bindings=7,bindings=9},
}
```

`result.report.module_stats` holds each retained module's pre-minification bytes, final bytes, and renamed-binding count. Mangling and whitespace removal have separate stage records, so their savings are not conflated. Standalone `minifier.minify` now returns its statistics as a second result while preserving source text as the first result.

`result.report.decisions` explains every retained module, removed module, and trimmed facade export. Retention decisions list incoming retained dependency edges. Removed modules are unreachable from the selected entry and verified export surface. Omitted facade exports cite the explicit profile and initializer proof. This is a graph/profile explanation, not an inferred explanation of the developer's intent.

Contracts also record inventory bytes, analyzed dependency-closure bytes/count, and output bytes. The analyzed closure is measured before facade selection, after any target specialization; it excludes unrelated inventory files. The legacy `reachable_input_bytes` field measures original text of retained modules and is not the full pre-selection closure.

These deterministic facts are included in `quaver-contract.lua`, including each regional contract. No clock values are included. Repeated bundle emission replaces the deterministic bundle-stage record rather than appending duplicate records.

## Run trace

`result.trace` is always available in memory. It contains the timed stage events separately from the report. The clock is **process CPU seconds**, using `os.clock`; it is not wall-clock latency or time spent waiting for I/O. Parent stages include their children's work, so summing nested durations double-counts time.

Set `trace=true` on a CLI or Ballad configuration to persist traces:

- CLI bundle: `<output>.trace.lua`.
- CLI module directory: `<output>/quaver-trace.lua`.
- Ballad: `quaver-trace.lua`, alongside contract output.
- Regional composition: one trace file containing host and region traces.

Trace emission is opt-in because timings change between runs and would otherwise cause the incremental sink to rewrite the trace every time. Source and contract artifacts remain reproducible regardless of tracing.

## Failures

Structured diagnostics retain their existing `QV` code, source location, explanation, and suggestion, and gain `stage` and, where known, `module`. Regional failures add `region` and reports from completed scopes. Unexpected plain Lua errors become `QV900`; validation failures become `QV001`.

```lua
local ok,result=pcall(require('quaver.build').build,options)
if not ok then
  print(tostring(result))
  local completed=result.partial_report.stages
  local trace=result.trace
end
```

The partial report includes successful work before the failure and failed enclosing stages. It contains statistics and diagnostics, not partially compiled source code. The deepest structured error keeps its identity as it propagates through enclosing stages. `require('quaver.report').failure(error)` serializes a data-only failure report containing the diagnostic, completed stages, CPU trace, completed regional scopes, and a UTC creation timestamp.

The CLI saves failures to `<output>.failure.lua` by default. Set `failure_report='path/to/failure.lua'` to choose a path, or `failure_report=false` to disable persistence. A failed build does not emit a new executable, although an artifact from an earlier successful invocation may still exist. Failure reports are not automatically deleted after a later successful build; their timestamps distinguish previous failures.

Ballad saves failures to `.ballad/quaver-failures/<node-id>.lua` by default, retaining the latest failure for that node. The same `failure_report` override is supported. It raises a native Ballad `quaver_failure` diagnostic whose `.quaver` field retains the structured Quaver error. Ballad's own failed-node event also contains the rendered stage diagnostic and report location.

If a report cannot be saved, the original compiler failure is still reported, with the persistence error as additional context. Errors during adapter hashing or filesystem emission retain completed compiler-stage information when available, but those adapter operations are not yet individually timed compiler passes. The CLI's directory creation currently requires a POSIX shell; Ballad's failure-directory creation uses its platform-aware process quoting.

The three compiler APIs remain independently importable. Full pipeline traces come from the build orchestrator; standalone tree-shaker and optimizer calls retain their own existing reports and diagnostics rather than automatically creating a build trace.
