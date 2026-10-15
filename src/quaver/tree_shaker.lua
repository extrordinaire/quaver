local lexer=require('quaver.lexer')
local facade=require('quaver.facade')
local literal=require('quaver.literal')
local diagnostic=require('quaver.diagnostic')
local contracts=require('quaver.contracts')
local M={}
local forbidden = { _G=true,_ENV=true,debug=true,load=true,loadstring=true,loadfile=true,dofile=true,getfenv=true,setfenv=true }
local function sorted_keys(t)
  local out={};for k in pairs(t) do out[#out+1]=k end;table.sort(out);return out
end
local function requires(source, id)
  local ts, deps, seen = lexer.scan(source), {}, {}
  for i,t in ipairs(ts) do
    local before=ts[i-1] and ts[i-1].text
    local after=ts[i+1] and ts[i+1].text
    local table_key=(before=='{' or before==',' or before==';') and after=='='
    if t.kind=='name' and forbidden[t.text] and not table_key and before~='.' and before~=':' then
      error(id..': reflective/dynamic Lua is unsupported ('..t.text..')',0)
    end
    -- A member named require is an ordinary API field, not the Lua loader.
    -- Bare references still reject aliasing and dynamic import arguments.
    if t.kind=='name' and t.text=='require' and before~='.' and before~=':' and not table_key then
      local argument=ts[i+1];local last=i+1
      if argument and argument.text=='(' then argument=ts[i+2];last=i+3
        if not ts[last] or ts[last].text~=')' then error(id..': require must have one literal argument',0) end
      end
      if not argument or argument.kind~='string' then error(id..': dynamic/aliased require is unsupported',0) end
      local name=literal.value(argument)
      if name:find('[/\\%z]') or name:find('..',1,true) or name=='' then error(id..': invalid module name '..name,0) end
      if not seen[name] then seen[name]=true;deps[#deps+1]=name end
    end
  end
  table.sort(deps);return deps
end
M.requires=requires
--- Closed-world module optimization. Facade selection needs an explicit
--- side-effect-free contract; export use is a consumer build profile.
---@param options {entry:string, modules?:table<string,string>, load?:fun(id:string):string?, facades?:table, externals?:table, minify?:boolean}
function M.shake(options)
  assert(type(options)=='table' and type(options.entry)=='string','entry is required')
  local function stage(record,fn)if options._telemetry then return options._telemetry:run(record,fn)end;return fn(record)end
  local mode=options.mode or 'conservative'
  assert(mode=='strict' or mode=='conservative','mode must be conservative or strict')
  local modules=options.modules or {}
  local originals={};for id,source in pairs(modules) do originals[id]=source end
  local function read(id)
    local source=originals[id] or originals[id..'.init']
    if source==nil and options.load then
      source=stage({stage='source_load',module=id},function(record)local value=options.load(id);record.output_bytes=value and #value or 0;return value end)
      if source then originals[id]=source end
    end
    return source
  end
  local boundaries=options.boundaries or {}
  local boundary_ids=sorted_keys(boundaries)
  for _,id in ipairs(boundary_ids) do
    local boundary=boundaries[id]
    if type(boundary)~='table' or boundary.kind~='runtime' or type(boundary.reason)~='string' or boundary.reason=='' then
      diagnostic.raise('QV001','Invalid runtime boundary: '..id,nil,1,id..'.lua','A boundary must state kind="runtime" and a reason.','Describe why this module needs dynamic runtime behavior.')
    end
  end
  local diagnostics={}
  local function preserve(reason)
    local entry=read(options.entry)
    if not entry then diagnostic.raise('QV103','Entry module is unavailable.',nil,1,options.entry..'.lua','Preserving behavior requires the entry source.','Supply the entry module and its source inventory.') end
    -- Inspect literal edges when possible, but never infer a closed graph
    -- from dynamic loading. Every supplied module is retained byte-for-byte.
    local visited={}
    local function discover(id)
      if visited[id] then return end;visited[id]=true
      local source=read(id);if not source then return end
      local ok,deps=pcall(requires,source,id)
      if ok then for _,dep in ipairs(deps) do discover(dep) end end
    end
    discover(options.entry)
    local kept=sorted_keys(originals);local bytes=0
    for _,source in pairs(originals) do bytes=bytes+#source end
    diagnostics[#diagnostics+1]=diagnostic.new('QV201',reason,entry,1,options.paths and options.paths[options.entry] or options.entry..'.lua',
      'Sources and runtime loading are preserved; declarations do not establish purity.',
      'Use strict mode for verifiable modules, or keep the runtime boundary as ordinary module files.','note')
    return {modules=originals,entry=options.entry,report={mode=mode,retained=kept,removed={},removed_exports={},dependencies={},
      input_bytes=bytes,reachable_input_bytes=bytes,output_bytes=bytes,diagnostics=diagnostics,boundaries=boundary_ids,
      proofs={},preserved=true,complete_inventory=options.modules~=nil}}
  end
  if mode=='conservative' and not options.modules then diagnostic.raise('QV203','Conservative mode requires a complete supplied source inventory.',nil,1,options.entry..'.lua','A lazy loader cannot enumerate runtime-discovered modules.','Pass modules explicitly, or use Ballad source assets.') end
  if #boundary_ids>0 and not options.modules then diagnostic.raise('QV203','Runtime boundaries require a complete supplied source inventory.',nil,1,options.entry..'.lua','Dynamic dependencies cannot be enumerated from a lazy loader.','Pass modules explicitly, or use Ballad source assets.') end
  if mode=='conservative' then return preserve('Conservative mode retained the supplied source inventory.') end
  if #boundary_ids>0 then
    return preserve('Declared runtime boundaries prevent a closed-world export proof; no sources were eliminated.')
  end
  -- Verify the original reachable closure before trimming a facade. Static
  -- registration and effects cannot disappear simply because pure=true was set.
  local closure,seen={},{ }
  local function collect(id)
    if seen[id] then return end;seen[id]=true
    local source,deps=stage({stage='dependency_scan',module=id},function(record)
      local source=read(id)
      if not source then
        if options.externals and options.externals[id]==true then record.counters={external=1};return nil,{} end
        diagnostic.raise('QV103','Unresolved module '..id,nil,1,options.paths and options.paths[id] or id..'.lua','Strict mode needs a complete literal dependency closure.','Supply this module, or declare a runtime boundary.')
      end
      closure[id]=source;record.input_bytes=#source
      local ok,deps=pcall(requires,source,id)
      if not ok then diagnostic.raise('QV102','Cannot analyze module loading: '..tostring(deps),source,1,options.paths and options.paths[id] or id..'.lua',
        'Strict mode requires literal, unaliased require calls.','Move dynamic discovery behind an explicit runtime boundary.') end
      record.counters={literal_dependencies=#deps};return source,deps
    end)
    if not source then return end
    for _,dep in ipairs(deps) do collect(dep) end
  end
  collect(options.entry)
  local verifier=contracts.verifier(read,options)
  for _,id in ipairs(sorted_keys(options.facades or {})) do
    local profile=options.facades[id]
    if type(profile.exports)~='table' then diagnostic.raise('QV001','Missing export profile.',nil,1,id..'.lua','Selected exports must be an array of names.','List the exports the consumer uses.') end
    local source=read(id)
    if not source then diagnostic.raise('QV103','Missing facade source: '..id,nil,1,id..'.lua','A profile requires inspectable source.','Supply this module, or retain it without a profile.') end
    stage({stage='export_proof',module=id},function()return verifier.stable(id,source)end)
    stage({stage='initializer_proof',module=id,input_bytes=#source},function(record)
      local before=#sorted_keys(verifier.proofs);local proof=verifier.pure(id)
      record.counters={verified_initializers=#sorted_keys(verifier.proofs)-before};return proof
    end)
  end
  stage({stage='consumer_proof',phase='original'},function()return contracts.consumers(closure,options.facades,read,options)end)
  local selected, dependencies, visiting, removed_exports = {}, {}, {}, {}
  local original_bytes=0
  local function visit(id)
    if visiting[id] then return end
    local source=read(id)
    if source==nil then
      if options.externals and options.externals[id]==true then return end
      error('unresolved module '..id,0)
    end
    assert(type(source)=='string','module source must be text: '..id)
    stage({stage='export_proof',module=id},function()return verifier.stable(id,source)end)
    visiting[id]=true;original_bytes=original_bytes+#source
    local profile=options.facades and options.facades[id]
    if profile then
      source,removed_exports[id]=stage({stage='export_selection',module=id,input_bytes=#source},function(record)
      local ok,output,removed=pcall(facade.select,source,profile.exports)
      if not ok then diagnostic.raise('QV101','Cannot select this facade: '..tostring(output),source,1,options.paths and options.paths[id] or id..'.lua','The first selector supports only static require assignments and aliases.','Use the supported facade shape, or retain the full module without a profile.') end
      record.output_bytes=#output;record.counters={removed_exports=#removed};return output,removed
      end)
    end
    dependencies[id]=requires(source,id)
    selected[id]=source
    for _,dep in ipairs(dependencies[id]) do visit(dep) end
  end
  visit(options.entry)
  local consumer_options={};for key,value in pairs(options) do consumer_options[key]=value end
  consumer_options.readonly_imports={}
  for id,proof in pairs(verifier.proofs) do if proof.value_kind=='table' then consumer_options.readonly_imports[id]=true end end
  stage({stage='consumer_proof',phase='retained'},function()return contracts.consumers(selected,options.facades,read,consumer_options)end)
  local analyzed_bytes=0;for _,source in pairs(closure)do analyzed_bytes=analyzed_bytes+#source end
  local retained=sorted_keys(selected)
  local removed={};local input_bytes=0;local output_bytes=0
  for _,id in ipairs(sorted_keys(originals)) do
    input_bytes=input_bytes+#originals[id]
    if not selected[id] then removed[#removed+1]=id end
  end
  for _,source in pairs(selected) do output_bytes=output_bytes+#source end
  return {modules=selected,entry=options.entry,report={mode=mode,retained=retained,removed=removed,
    removed_exports=removed_exports,dependencies=dependencies,input_bytes=input_bytes,
    reachable_input_bytes=original_bytes,analyzed_closure_bytes=analyzed_bytes,analyzed_closure_modules=#sorted_keys(closure),output_bytes=output_bytes,diagnostics=diagnostics,
    proofs=verifier.proofs,boundaries=boundary_ids}}
end
return M
