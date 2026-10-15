local build=require('quaver.build').build
local bundle=require('quaver.bundle').bundle
local report=require('quaver.report')
local count=0
local function test(name,fn)fn();count=count+1;print('PASS telemetry: '..name)end
local function config()
 return {mode='strict',entry='app',minify={level='mangle'},modules={
  app='local library=require("api");return function()return library.used()end',
  api='local api={} api.used=require("used") api.unused=require("unused") return api',
  used='local long_value=42;return function()return long_value end',unused='return function()return 0 end'},
  facades={api={exports={'used'}}}}
end
local function decode(source)return assert((loadstring or load)(source))()end
local function failure(options)
 local ok,err=pcall(build,options);assert(not ok and type(err)=='table' and err.code,tostring(err));return err
end
test('stage records contain real byte reductions and binding counters',function()
 local result=build(config());local found={}
 for _,stage in ipairs(result.report.stages)do
  assert(stage.status=='success');assert(stage.elapsed_seconds==nil)
  found[stage.stage]=true
  if stage.stage=='mangle'and stage.module=='used'then
   assert(stage.counters.renamed_bindings==1 and stage.output_bytes<stage.input_bytes)
  end
 end
 for _,name in ipairs({'validation','tree_shake','dependency_scan','export_proof','initializer_proof','consumer_proof','export_selection','mangle','minify'})do assert(found[name],name)end
 assert(result.report.module_stats.used.renamed_bindings==1)
 local source=bundle(result)
 assert(result.report.stages[#result.report.stages].stage=='bundle'and result.report.stages[#result.report.stages].output_bytes==#source)
 for _,event in ipairs(result.trace.events)do assert(event.status=='success'and event.elapsed_seconds>=0)end
 assert(result.trace.clock=='process_cpu_seconds')
end)
test('deterministic contracts exclude timings and repeated emission is stable',function()
 local a,b=build(config()),build(config());bundle(a);bundle(b)
 assert(report.render(a)==report.render(b))
 local first=report.render(a);bundle(a);assert(report.render(a)==first)
 assert(not first:find('elapsed_seconds',1,true))
end)
test('every retained, removed and trimmed export has an explanation',function()
 local result=build(config());local kept,removed,export=false,false,false
 for _,decision in ipairs(result.report.decisions)do
  assert(decision.reason and decision.reason~='')
  if decision.module=='used'and decision.action=='retain'then kept=true;assert(decision.parents[1]=='api')end
  if decision.module=='unused'and decision.action=='remove'then removed=true end
  if decision.module=='api'and decision.export=='unused'then export=true end
 end
 assert(kept and removed and export)
end)
test('initializer failures preserve earlier stages and the actual dependency identity',function()
 local options=config();options.modules.unused='external_state=1;return {}'
 local err=failure(options)
 assert(err.code=='QV105'and err.stage=='initializer_proof'and err.module=='unused')
 assert(err.partial_report.status=='failed'and #err.partial_report.stages>2)
 local record=decode(report.failure(err));assert(record.status=='failed'and record.diagnostic.code=='QV105')
 local successful=false
 for _,stage in ipairs(record.partial_report.stages)do if stage.stage=='dependency_scan'and stage.status=='success'then successful=true end end
 assert(successful)
end)
test('mangling and source loading failures identify their pipeline stages',function()
 local err=failure({mode='strict',entry='app',modules={app='return function()return package.loaded end'},minify={level='mangle'}})
 assert(err.code=='QV111'and err.stage=='mangle'and err.module=='app')
 local loader=failure({mode='strict',entry='app',load=function()error('network fixture failure')end})
 assert(loader.code=='QV900'and loader.partial_report and loader.stage=='source_load'and loader.module=='app')
 local missing=failure({mode='strict',entry='app',modules={app='return require("absent")'}})
 assert(missing.code=='QV103'and missing.stage=='dependency_scan'and missing.module=='absent')
end)
test('invalid configurations are structured validation diagnostics',function()
 local err=failure({entry='app',minify={level='unknown'}})
 assert(err.code=='QV001'and err.stage=='validation')
end)
test('standalone minifier returns mangling statistics without changing its first result',function()
 local output,stats=require('quaver.minifier').minify('local long_name=42;return long_name',{level='mangle'})
 assert(stats.renamed_bindings==1 and stats.input_bytes>stats.output_bytes and stats.output_bytes==#output)
 assert(decode(output)==42)
end)
test('regional failures retain completed scopes',function()
 local compiler=require('quaver.regions')
 local ok,err=pcall(compiler.build,{host={entry='app',modules={app='return {}'}},regions={
  alpha={entry='app',modules={app='return 1'}},omega={entry='app',modules={app='return require(dynamic)'}}}})
 assert(not ok and err.region=='omega'and err.completed_scopes.regions.alpha and err.completed_scopes.host)
 assert(decode(report.failure(err)).completed_scopes.regions.alpha.mode=='strict')
end)
print(count..' telemetry tests passed')
