local shaker=require('quaver.tree_shaker')
local minifier=require('quaver.minifier')
local optimize=require('quaver.optimizer').optimize
local diagnostic=require('quaver.diagnostic')
local telemetry=require('quaver.telemetry')
local M={}
--- Compose conservative passes. AST specialization can prune proven dead
--- flavor branches; general statement DCE, renaming and arithmetic are absent.
function M.build(options)
  local session=telemetry.new()
  return session:run({stage='build'},function(build_record)
  local mode,minify_level=session:run({stage='validation'},function()
    assert(type(options)=='table','build options must be a table')
    assert(type(options.entry)=='string','entry must be a module name')
    local mode=options.mode or 'conservative'
    assert(mode=='strict' or mode=='conservative','mode must be conservative or strict')
    return mode,minifier.level(options.minify,'none')
  end)
  local build={};for key,value in pairs(options) do build[key]=value end
  build._telemetry=session
  if mode=='strict' and options.assume_runtime_globals then diagnostic.raise('QV108','Strict mode cannot assume runtime globals are immutable.',nil,1,options.entry..'.lua','An assumption flag is not a proof of runtime global identity.','Use Moonstone metadata, or call the low-level optimizer with an explicitly assumed runtime contract.') end
  local context=options.target_context
  local can_transform=mode=='strict' and not next(options.boundaries or {})
  if context and can_transform then
    assert(not(options.modules and (options.modules.moonstone or options.modules['moonstone.target'] or options.modules['moonstone.project'])),
      'flavor builds must use runtime Moonstone metadata, not bundle host data modules')
    build.externals={moonstone=true,['moonstone.target']=true,['moonstone.project']=true,['moonstone.variants']=true}
    for id,enabled in pairs(options.externals or {}) do build.externals[id]=enabled end
    local original=options.modules or {};local transformed={};local reports={}
    local function transform(id,source)
      if source==nil then return nil end
      local output,report=session:run({stage='specialize',module=id,input_bytes=#source},function(record)
        local output,report=optimize(source,context,{assume_runtime_globals=options.assume_runtime_globals})
        record.output_bytes=#output;record.counters=report;return output,report
      end)
      reports[id]=report;return output
    end
    -- Transform lazily after module/file selection; unselected foreign syntax
    -- must never reach the parser. Facade selection still happens in shaker.
    build.modules={}
    build.load=function(id)
      if transformed[id] then return transformed[id] end
      local source=original[id] or original[id..'.init']
      if source==nil and options.load then source=options.load(id) end
      local output=transform(id,source);transformed[id]=output;return output
    end
    build.specialization_reports=reports
  end
  local result=session:run({stage='tree_shake'},function(record)
    local result=shaker.shake(build)
    record.input_bytes=result.report.input_bytes;record.output_bytes=result.report.output_bytes
    record.counters={retained_modules=#result.report.retained,removed_modules=#result.report.removed}
    return result
  end)
  if context and can_transform then
    result.report.target=context.target.id
    result.report.runtime_known=context.runtime_known
    result.report.specialization=build.specialization_reports
    result.report.input_bytes=0;result.report.removed={}
    for id,source in pairs(options.modules or {}) do
      result.report.input_bytes=result.report.input_bytes+#source
      if not result.modules[id] then result.report.removed[#result.report.removed+1]=id end
    end
    table.sort(result.report.removed)
  end
  if result.report.preserved and (minify_level~='none' or options.target_context or next(options.facades or {})) then
    result.report.diagnostics[#result.report.diagnostics+1]=diagnostic.new('QV202','Requested optimizations were withheld because their contracts are unproven.',nil,1,options.entry..'.lua','Conservative mode and runtime boundaries never grant extra assumptions.','Use an analyzable strict artifact for export selection or specialization.','note')
  end
  result._mangle_target=context and context.target
  result.report.minification={requested=minify_level,applied=result.report.preserved and 'none' or minify_level}
  result.report.before_minify_bytes=result.report.output_bytes
  local total=0
  result.report.module_stats={}
  for _,id in ipairs(result.report.retained) do
    local source=result.modules[id];local input_bytes=#source;local renamed=0
    if result.report.minification.applied=='mangle' then
      local output,stats=session:run({stage='mangle',module=id,input_bytes=#source},function(record)
        local ok,output,stats=pcall(require('quaver.mangle').mangle,source,context and context.target)
        if not ok then
          if type(output)=='table' and output.code then output.path=options.paths and options.paths[id] or id..'.lua' end
          error(output,0)
        end
        record.output_bytes=#output;record.counters={renamed_bindings=stats.renamed,bindings=stats.bindings}
        return output,stats
      end)
      source=output;renamed=stats.renamed
    end
    if result.report.minification.applied~='none' then
      source=session:run({stage='minify',module=id,input_bytes=#source},function(record)
        local ok,output=pcall(minifier.minify,source,{level=minify_level=='mangle' and 'compact' or minify_level},context and context.target)
        if not ok then
          if type(output)=='table' and output.code then output.path=options.paths and options.paths[id] or id..'.lua' end
          error(output,0)
        end
        record.output_bytes=#output;return output
      end)
    else
      session:skip({stage='minify',module=id,input_bytes=#source,output_bytes=#source},
        result.report.preserved and 'Correctness mode preserves source bytes' or 'Minification disabled')
    end
    result.modules[id]=source
    result.report.module_stats[id]={input_bytes=input_bytes,output_bytes=#source,renamed_bindings=renamed}
    total=total+#source
  end
  result.report.output_bytes=total
  local parents={}
  for parent,deps in pairs(result.report.dependencies)do for _,id in ipairs(deps)do
    parents[id]=parents[id] or {};parents[id][#parents[id]+1]=parent
  end end
  local decisions={}
  for _,id in ipairs(result.report.retained)do
    local incoming=parents[id] or {};table.sort(incoming)
    decisions[#decisions+1]={module=id,action='retain',parents=incoming,reason=result.report.preserved and 'Preserved source inventory'
      or id==result.entry and 'Entry module' or 'Literal dependency of retained modules'}
  end
  for _,id in ipairs(result.report.removed)do decisions[#decisions+1]={module=id,action='remove',reason='Unreachable from the selected entry and verified exports'}end
  for _,id in ipairs(result.report.retained)do for _,field in ipairs(result.report.removed_exports[id] or {})do
    decisions[#decisions+1]={module=id,export=field,action='remove_export',reason='Omitted by the explicit profile; initializer closure verified'}
  end end
  session.report.status='success';result.report.stages=session.report.stages;result.report.decisions=decisions
  result.trace=session.trace
  build_record.input_bytes=result.report.input_bytes;build_record.output_bytes=result.report.output_bytes
  return result
  end)
end
return M
