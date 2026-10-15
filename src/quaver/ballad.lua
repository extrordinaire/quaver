local build=require('quaver.build').build
local bundle=require('quaver.bundle').bundle
local version=require('quaver.version')
local graph = require('ballad.graph')
local M={name='quaver.ballad',version=version,
  methods={optimize={inputs={'asset_set'},outputs={'asset_set'},cacheable=false,parallel_safe=true},
    compose={inputs={'asset_set'},outputs={'asset_set'},cacheable=false,parallel_safe=true}}}
local function collect(inputs,options)
  options=options or {}
  local modules={}
  local files,paths={},{}
  local flavors=require('quaver.flavors')
  local context=flavors.context(options)
  for _,set in ipairs(inputs) do for _,asset in ipairs(set.assets) do
    local path=asset.virtual_path
    if path and path:match('%.lua$') then
      local relative=path
      for _,root in ipairs(options.roots or {}) do
        if path:sub(1,#root+1)==root..'/' then relative=path:sub(#root+2);break end
      end
      local id=relative:gsub('%.lua$',''):gsub('/','.')
      assert(not modules[id],'duplicate module '..id)
      local source=asset.content
      if source==nil then
        local f=assert(io.open(assert(asset.source_path),'rb'));source=f:read('*a');f:close()
      end
      modules[id]=source;paths[id]=asset.source_path or relative
      assert(not files[relative],'duplicate source '..relative);files[relative]=source
    else error('Quaver expects only .lua module assets; filter inputs first',0) end
  end end
  local selected
  if context then modules,selected=flavors.select(files,context) end
  local config={};for key,value in pairs(options)do config[key]=value end
  config.modules=modules;config.paths=paths;config.target_context=context
  return config,selected
end
local function hash_source(source)
  local hash=require('ballad.process').b3sum_string(source)
  assert(type(hash)=='string' and #hash==64 and hash:match('^[a-f0-9]+$'),'BLAKE3 hashing failed')
  return hash
end
function M.optimize(ctx,inputs,options)
  options=options or {}
  local config,selected=collect(inputs,options)
  local modules,context=config.modules,config.target_context
  local result=build(config)
  if ctx then ctx._quaver_result=result end
  result.report.selected_files=selected
  local out=graph.AssetSet.new()
  if options.format=='bundle' then
    out:add(graph.Asset.new({kind='generated',generated=true,virtual_path=options.name or 'app.lua',content=bundle(result),metadata={quaver=result.report}}))
  else
    assert(options.format==nil or options.format=='files','format must be files or bundle')
    for _,id in ipairs(result.report.retained) do
      out:add(graph.Asset.new({kind='generated',generated=true,virtual_path=id:gsub('%.','/')..'.lua',content=result.modules[id],metadata={quaver=result.report}}))
    end
  end
  local manifest=require('quaver.report').render(result,options,modules,hash_source)
  out:add(graph.Asset.new({kind='generated',generated=true,virtual_path='quaver-contract.lua',content=manifest}))
  if options.trace then out:add(graph.Asset.new({kind='generated',generated=true,virtual_path='quaver-trace.lua',content='return '..require('quaver.report').encode(result.trace)..'\n'}))end
  local lines={ 'Quaver '..version, 'entry: '..result.entry,
    'retained modules: '..#result.report.retained,'removed modules: '..#result.report.removed,
    'input bytes: '..result.report.input_bytes,'output module bytes: '..result.report.output_bytes }
  if context then lines[#lines+1]='target: '..context.target.id;lines[#lines+1]='runtime known: '..tostring(context.runtime_known) end
  lines[#lines+1]='mode: '..result.report.mode
  lines[#lines+1]='minification: '..result.report.minification.applied..' (requested '..result.report.minification.requested..')'
  for _,note in ipairs(result.report.diagnostics) do lines[#lines+1]=tostring(note) end
  for _,id in ipairs(result.report.retained) do
    lines[#lines+1]='keep '..id
    if selected and selected[id] then lines[#lines+1]='select '..id..' <- '..selected[id] end
  end
  for _,id in ipairs(result.report.removed) do lines[#lines+1]='drop '..id end
  out:add(graph.Asset.new({kind='generated',generated=true,virtual_path='quaver-report.txt',content=table.concat(lines,'\n')..'\n'}))
  return out
end
function M.compose(ctx,inputs,options)
  options=options or {}
  local diagnostic=require('quaver.diagnostic')
  local function fail(message)
    diagnostic.raise('QV301',message,nil,1,'<ballad-regions>','Every scope needs explicitly assigned declared inputs.','Set host.inputs and regions.<name>.inputs to arrays of input indexes.')
  end
  if type(options.host)~='table' or type(options.regions)~='table' then fail('Regional composition requires host and regions.') end
  local used={}
  local function scope(config)
    if type(config)~='table' or type(config.inputs)~='table' or #config.inputs==0 then fail('A regional scope has no declared inputs.') end
    local sets,seen={},{}
    for _,index in ipairs(config.inputs)do
      if type(index)~='number' or index%1~=0 or not inputs[index] then fail('Invalid regional input index: '..tostring(index)) end
      if seen[index] then fail('Repeated regional input index: '..index) end
      seen[index]=true;used[index]=true;sets[#sets+1]=inputs[index]
    end
    return collect(sets,config)
  end
  local config={host=scope(options.host),regions={}}
  local names={};for name in pairs(options.regions)do names[#names+1]=name end;table.sort(names)
  for _,name in ipairs(names)do config.regions[name]=scope(options.regions[name]) end
  for index in ipairs(inputs)do if not used[index] then fail('Declared input '..index..' is not assigned to any regional scope.') end end
  local compiler=require('quaver.regions')
  local result=compiler.build(config)
  if ctx then ctx._quaver_result=result end
  local files=compiler.files(result,config,hash_source)
  if options.trace then
    local trace={host=result.host.trace,regions={}}
    for name,region in pairs(result.regions)do trace.regions[name]=region.trace end
    files['quaver-trace.lua']='return '..require('quaver.report').encode(trace)..'\n'
  end
  local out=graph.AssetSet.new()
  local paths={};for path in pairs(files)do paths[#paths+1]=path end;table.sort(paths)
  for _,path in ipairs(paths)do out:add(graph.Asset.new({kind='generated',generated=true,virtual_path=path,content=files[path]})) end
  return out
end
local function guarded(handler)
 return function(ctx,inputs,options)
  local ok,result=pcall(handler,ctx,inputs,options)
  if ok then return result end
  local diagnostic=require('quaver.diagnostic')
  if type(result)~='table' or not result.code then result=diagnostic.new('QV900',tostring(result),nil,1,'<ballad>','Quaver adapter execution failed.','Check declared inputs, output format, and hashing tools.')end
  local previous=ctx and ctx._quaver_result
  result.stage=result.stage or (previous and 'adapter_emit' or 'adapter')
  if previous and not result.partial_report then
   local compiled=previous.host or previous
   result.partial_report={status='failed',stages=compiled.report.stages};result.trace=compiled.trace
   if previous.regions then
    result.completed_scopes={host=previous.host.report,regions={}}
    for name,region in pairs(previous.regions)do result.completed_scopes.regions[name]=region.report end
   end
  end
  local path=options and options.failure_report
  if path==nil then path='.ballad/quaver-failures/'..tostring(ctx and ctx.node and ctx.node.id or 'adapter'):gsub('[^%w_-]','_')..'.lua' end
  local saved,save_error
  if path~=false then
   saved,save_error=pcall(function()
    local process=require('ballad.process');local directory=require('ballad.path').dirname(path)
    if directory~='' and directory~='.' then
      local command=process.is_windows() and ('if not exist '..process.quote(directory)..' mkdir '..process.quote(directory)) or ('mkdir -p '..process.quote(directory))
      assert(process.command_ok(command),'cannot create report directory')
    end
    local f=assert(io.open(path,'wb'));local ok,err=f:write(require('quaver.report').failure(result));f:close();assert(ok,err)
   end)
  end
  local value=require('ballad.diagnostic').new({code='quaver_failure',message=tostring(result),
   hint=path~=false and (saved and 'Partial report: '..path or 'Could not save partial report: '..tostring(save_error)) or nil})
  value.quaver=result
  error(value,0)
 end
end
M.optimize=guarded(M.optimize)
M.compose=guarded(M.compose)
return M
