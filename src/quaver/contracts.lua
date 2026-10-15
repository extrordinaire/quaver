-- Proofs for a deliberately small, checkable module model. Declarations do
-- not certify themselves: `pure=true` is not consulted by this verifier.
local ast=require('quaver.ast')
local diagnostic=require('quaver.diagnostic')
local M={}
local function walk(value,visit,parent)
 if type(value)~='table' then return end
 if value.kind and visit(value,parent)==false then return end
 local keys={};for key in pairs(value) do keys[#keys+1]=key end
 table.sort(keys,function(a,b)if type(a)==type(b) then return a<b end;return type(a)<type(b) end)
 for _,key in ipairs(keys) do local v=value[key];if type(v)=='table' then walk(v,visit,value.kind and value or parent) end end
end
local function root(n)
 while n and (n.kind=='Member' or n.kind=='Index') do n=n.object end
 return n and n.kind=='Identifier' and n.name
end
local function required(n)
 if n and n.kind=='Call' and n.callee.kind=='Identifier' and n.callee.name=='require' and #n.args==1
  and n.args[1].kind=='Literal' and type(n.args[1].value)=='string' then return n.args[1].value end
end
M.required=required
function M.verifier(read,options)
 options=options or {};local cache,active,structural={},{},{}
 local function fail(id,source,node,code,message,suggestion)
  local err=diagnostic.new(code,message,source,node and node.start,options.paths and options.paths[id] or id..'.lua',
    code=='QV104' and 'Strict optimization requires exports to remain structurally stable.'
      or 'Removing an initializer requires a verified effect-free dependency closure.',suggestion)
  err.module=id;error(err,0)
 end
 local function parse(id,source)
  local ok,tree=pcall(ast.parse,source,options.target_context and options.target_context.target)
  if not ok then fail(id,source,nil,'QV101','Cannot analyze module syntax: '..tostring(tree),'Declare this module as a runtime boundary, or use a supported frontend.') end
  return tree
 end
 local function stable(id,source,tree)
  local returned=tree.statements[#tree.statements]
  while returned and returned.kind=='Empty' do table.remove(tree.statements);returned=tree.statements[#tree.statements] end
  if not returned or returned.kind~='Return' or #returned.values~=1 then
   fail(id,source,returned,'QV104','Cannot prove that module exports are immutable.','Return one stable value, or declare a runtime boundary.')
  end
  local value=returned.values[1]
  if value.kind=='Literal' or value.kind=='Function' or value.kind=='Table' then return true end
  -- Forwarders inherit their dependency's structure rather than asserting it.
  if required(value) then return true end
  if value.kind~='Identifier' then fail(id,source,value,'QV104','Cannot prove that module exports are immutable.','Move dynamic registration behind an explicit runtime boundary.') end
  local export=value.name;local declarations=0;local is_table=false;local is_function=false;local is_import=false
  for _,stmt in ipairs(tree.statements) do
   if stmt.kind=='Local' then for index,name in ipairs(stmt.names) do if name==export then
    declarations=declarations+1;local init=stmt.values[index];is_table=init and init.kind=='Table';is_function=init and init.kind=='Function';is_import=required(init)~=nil
   end end
   elseif stmt.kind=='LocalFunction' and stmt.name==export then declarations=declarations+1;is_function=true end
  end
  if declarations~=1 or not(is_table or is_function or is_import) then
   fail(id,source,value,'QV104','Cannot prove that module exports are immutable.','Construct exports locally, or declare the module as a runtime boundary.')
  end
  local top_assignments={}
  for _,stmt in ipairs(tree.statements) do if stmt.kind=='Assignment' then top_assignments[stmt]=true end end
  walk(tree,function(n,parent)
   if n.kind=='Assignment' then for _,target in ipairs(n.targets) do if root(target)==export then
    if not top_assignments[n] or target.object==nil or target.object.kind~='Identifier' or not(target.kind=='Member' or (target.kind=='Index' and target.key.kind=='Literal' and type(target.key.value)=='string')) then
     fail(id,source,target,'QV104','Cannot prove that module exports are immutable.','Move dynamic registration behind an explicit runtime boundary.')
    end
   end end end
   if n.kind=='Identifier' and n.name==export then
    if n==value and parent==returned then return end
    if not(parent and (parent.kind=='Member' or parent.kind=='Index') and parent.object==n) then
     fail(id,source,n,'QV104','Module exports escape before their structure can be verified.','Keep the exports table private until return, or declare a runtime boundary.')
    end
   end
  end)
  return true
 end
 local prove
 prove=function(id)
  if cache[id] then return cache[id] end
  if active[id] then diagnostic.raise('QV106','Cannot prove a cyclic initialization graph.',nil,1,id..'.lua','Initializer proofs must terminate without assuming cycle behavior.','Break the initializer cycle, or preserve it behind a runtime boundary.') end
  if options.boundaries and options.boundaries[id] then
   diagnostic.raise('QV105','A runtime boundary cannot certify an initializer as pure.',nil,1,id..'.lua','A boundary preserves dynamic behavior; it is not a purity assertion.','Retain the initializer instead of selecting away its export.')
  end
  local source=read(id)
  if not source then diagnostic.raise('QV105','Cannot inspect initializer '..id..'.',nil,1,id..'.lua','External code does not gain a purity proof from a declaration.','Supply its source, or retain the initializer behind a runtime boundary.') end
  active[id]=true;local tree=parse(id,source)
  local locals,owned,kinds,dependencies={},{},{},{}
  local pure
  pure=function(n)
   if not n then return true end
   if n.kind=='Literal' or n.kind=='Function' then return true end
   if n.kind=='Paren' then return pure(n.value) end
   if n.kind=='Identifier' then return locals[n.name]==true end
   if n.kind=='Table' then for _,f in ipairs(n.fields) do if f.key and (not pure(f.key) or f.key.kind~='Literal' or f.key.value==nil) then return false end;if not pure(f.value) then return false end end;return true end
   local dependency=required(n)
   if dependency then prove(dependency);dependencies[dependency]=true;return true end
   if n.kind=='Member' then
    local dep=required(n.object)
    if dep then local proof=prove(dep);dependencies[dep]=true;if proof.value_kind=='table' then stable(dep,assert(read(dep)),parse(dep,assert(read(dep))));structural[dep]=true;proof.exports='stable';return true end;return false end
    return n.object.kind=='Identifier' and owned[n.object.name]==true
   end
   return false
  end
  for _,stmt in ipairs(tree.statements) do
   if stmt.kind=='Local' then
    for _,attribute in pairs(stmt.attributes or {}) do if attribute=='close' then fail(id,source,stmt,'QV105','Cannot discard a to-be-closed initializer.','Retain its scope and closing behavior.') end end
    for _,value in ipairs(stmt.values) do if not pure(value) then fail(id,source,value,'QV105','Cannot prove that module initialization is effect-free.','Retain this initializer, or move the effect into an explicit runtime boundary.') end end
    for index,name in ipairs(stmt.names) do
     local value=stmt.values[index]
     if not pure(value) then fail(id,source,value,'QV105','Cannot prove that module initialization is effect-free.','Retain this initializer, or move the effect into an explicit runtime boundary.') end
     locals[name]=true;owned[name]=value and value.kind=='Table' or false
     kinds[name]=value and (value.kind=='Table' and 'table' or value.kind=='Function' and 'function' or value.kind=='Literal' and type(value.value)) or 'nil'
     if value and required(value) then kinds[name]=prove(required(value)).value_kind end
    end
   elseif stmt.kind=='LocalFunction' then locals[stmt.name]=true;kinds[stmt.name]='function'
   elseif stmt.kind=='Assignment' then
    for index,target in ipairs(stmt.targets) do
     if not((target.kind=='Identifier' and locals[target.name]) or ((target.kind=='Member' or (target.kind=='Index' and target.key.kind=='Literal' and type(target.key.value)=='string')) and target.object.kind=='Identifier' and owned[root(target)])) or not pure(stmt.values[index]) then
      fail(id,source,stmt,'QV105','Cannot prove that module initialization is effect-free.','Use local construction without calls or global writes, or retain the initializer.')
     end
     if target.kind=='Identifier' then
       local value=stmt.values[index];owned[target.name]=value and value.kind=='Table' or false
       kinds[target.name]=value and (value.kind=='Table' and 'table' or value.kind=='Function' and 'function' or value.kind=='Literal' and type(value.value)) or 'nil'
     end
    end
   elseif stmt.kind=='Return' then
    for _,value in ipairs(stmt.values) do if not pure(value) then fail(id,source,value,'QV105','Cannot prove that the returned value is effect-free.','Return a locally constructed value, or retain the initializer.') end end
   elseif stmt.kind~='Empty' then fail(id,source,stmt,'QV105','Cannot prove that module initialization is effect-free.','Move initialization effects behind an explicit boundary; declaring pure=true is insufficient.') end
  end
  active[id]=nil
  local deps={};for dep in pairs(dependencies) do deps[#deps+1]=dep end;table.sort(deps)
  local returned=tree.statements[#tree.statements];local value=returned and returned.values and returned.values[1]
  local kind=value and (value.kind=='Table' and 'table' or value.kind=='Function' and 'function' or value.kind=='Literal' and type(value.value) or value.kind=='Identifier' and kinds[value.name]) or 'unknown'
  if required(value) then kind=prove(required(value)).value_kind end
  cache[id]={module=id,value_kind=kind,initializer='verified',exports=structural[id] and 'stable' or 'not_checked',dependencies=deps};return cache[id]
 end
 return {pure=prove,stable=function(id,source)local result=stable(id,source,parse(id,source));structural[id]=true;if cache[id] then cache[id].exports='stable' end;return result end,parse=parse,proofs=cache}
end
-- Verify actual imports of selected facades. A profile is not evidence that
-- its consumer refrains from mutation, escape, or dynamic property access.
function M.consumers(modules,facades,read,options)
 options=options or {};local profiles={}
 for id in pairs(facades or {}) do profiles[id]=true end
 for id in pairs(options.readonly_imports or {}) do profiles[id]=true end
 local aliases={}
 for id,source in pairs(modules) do
  local ok,tree=pcall(ast.parse,source,options.target_context and options.target_context.target)
  if ok and #tree.statements==1 then local stmt=tree.statements[1];if stmt.kind=='Return' and #stmt.values==1 then aliases[id]=required(stmt.values[1]) end end
 end
 local function profile(id)
  local seen={};while aliases[id] and not seen[id] do seen[id]=true;id=aliases[id] end
  return profiles[id] and id
 end
 local readonly_fields={}
 for id in pairs(facades or {}) do
  local source=modules[id]
  if source then
   local tree=ast.parse(source,options.target_context and options.target_context.target)
   readonly_fields[id]={}
   for _,stmt in ipairs(tree.statements) do if stmt.kind=='Assignment' then
    for index,target in ipairs(stmt.targets) do
     local dep=required(stmt.values[index]);local key=target.kind=='Member' and target.key or target.kind=='Index' and target.key.value
     if dep and options.readonly_imports and options.readonly_imports[dep] and key then readonly_fields[id][key]=true end
     local value=stmt.values[index]
     local alias=value and (value.kind=='Member' and value.key or value.kind=='Index' and value.key.value)
     if key and alias and root(target)==root(value) and readonly_fields[id][alias] then readonly_fields[id][key]=true end
    end
   end end
  end
 end
 local ids={};for id in pairs(modules) do ids[#ids+1]=id end;table.sort(ids)
 for _,id in ipairs(ids) do
  local source=modules[id];local ok,tree=pcall(ast.parse,source,options.target_context and options.target_context.target)
  if not ok then diagnostic.raise('QV101','Cannot verify facade consumers: '..tostring(tree),source,1,options.paths and options.paths[id] or id..'.lua','Strict mode cannot hide an unsupported consumer.','Declare a runtime boundary, or use supported syntax.') end
  local bindings={}
  walk(tree,function(n)
   if n.kind=='Local' then for index,name in ipairs(n.names) do local dep=required(n.values[index]);if dep and profile(dep) then bindings[name]=profile(dep) end end end
  end)
  local declarations={}
  walk(tree,function(n)
   if n.kind=='Local' then for _,name in ipairs(n.names) do declarations[name]=(declarations[name] or 0)+1 end end
   if n.kind=='Function' then for _,name in ipairs(n.params or {}) do declarations[name]=(declarations[name] or 0)+1 end end
  end)
  walk(tree,function(n,parent)
   local function fail(node,message)
    diagnostic.raise('QV104',message,source,node.start,options.paths and options.paths[id] or id..'.lua',
      'Strict optimization requires exports to remain structurally stable.','Move dynamic registration behind an explicit runtime boundary.')
   end
   local dep=required(n)
   if dep and profile(dep) then
    local bound=false
    if parent and parent.kind=='Local' then
     for index,value in ipairs(parent.values) do if value==n and bindings[parent.names[index]] then bound=true end end
    end
    local facade_export=facades and facades[id] and parent and parent.kind=='Assignment'
    if facade_export then
     facade_export=false
     for index,value in ipairs(parent.values) do
      local target=parent.targets[index]
      if value==n and target and (target.kind=='Member' or target.kind=='Index') then facade_export=true end
     end
    end
    if not bound and not facade_export and not (aliases[id] and parent and parent.kind=='Return') and not (not (facades and facades[profile(dep)]) and parent and parent.kind=='Member' and parent.object==n) then fail(n,'Selected facade imports must use a private local binding.') end
   end
   if n.kind=='Assignment' then for _,target in ipairs(n.targets) do
    local base=target;while base.object do base=base.object end
    if bindings[root(target)] or (required(base) and profile(required(base))) then fail(target,'Cannot prove that module exports are immutable.') end
   end end
   if n.kind=='Member' and n.object.kind=='Identifier' and bindings[n.object.name] then
    local fields=readonly_fields[bindings[n.object.name]]
    if fields and fields[n.key] and not (parent and parent.kind=='Member' and parent.object==n) then
     fail(n,'An imported exports table escapes through a facade field.')
    end
   end
   if n.kind=='Identifier' and bindings[n.name] then
    if declarations[n.name]~=1 then fail(n,'Selected facade binding is shadowed; scope cannot be proved.') end
    if not(parent and parent.kind=='Member' and parent.object==n) then fail(n,'Module exports escape or use a dynamic index.') end
    local selection=facades and facades[bindings[n.name]]
    local selected=selection and selection.exports or {};local allowed={};for _,field in ipairs(selected) do allowed[field]=true end
    if selection and not allowed[parent.key] then
     diagnostic.raise('QV107','Consumer uses export omitted by its profile: '..parent.key,source,parent.start,options.paths and options.paths[id] or id..'.lua',
      'An explicit profile must cover every observable export read.','Add '..parent.key..' to the export profile, or retain the full facade.')
    end
   end
  end)
 end
end
return M
