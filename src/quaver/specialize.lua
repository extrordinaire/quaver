local ast=require('quaver.ast')
local M={}
local function walk(value,visit,parent,key)
 if type(value)~='table' then return end
 if value.kind and visit(value,parent,key)==false then return end
 for k,v in pairs(value) do if type(v)=='table' then walk(v,visit,value,k) end end
end
local function chain(n)
 local keys={}
 while n and (n.kind=='Member' or n.kind=='Index') do
  local key
  if n.kind=='Member' then key=n.key elseif n.key.kind=='Literal' then key=n.key.value else return nil end
  if key==nil then return nil end
  table.insert(keys,1,key);n=n.object
 end
 if n and n.kind=='Identifier' then return n.name,keys end
end
local function module_call(n)
 if n and n.kind=='Call' and n.callee.kind=='Identifier' and n.callee.name=='require'
   and #n.args==1 and n.args[1].kind=='Literal' and type(n.args[1].value)=='string' then return n.args[1].value end
end
local function imported(n)
 local id=module_call(n)
 if id=='moonstone.target' then return 'target' elseif id=='moonstone.project' then return 'project' end
 if n and n.kind=='Member' and module_call(n.object)=='moonstone' and (n.key=='target' or n.key=='project') then return n.key end
end
local function quote(value)
 if type(value)=='string' then return string.format('%q',value) end
 if value==nil or type(value)=='number' or type(value)=='boolean' then return tostring(value) end
end
function M.specialize(source,context,options)
 options=options or {}
 assert(context and context.target,'specialization requires a target context')
 local tree=ast.parse(source,context.target)
 local bindings,declared,writes,imports={},{},{},{target=0,project=0}
 local function declare(name) declared[name]=(declared[name] or 0)+1 end
 walk(tree,function(n,parent)
  if n.kind=='Local' then for _,name in ipairs(n.names) do declare(name) end
  elseif n.kind=='LocalFunction' then declare(n.name)
  elseif n.kind=='Function' then for _,name in ipairs(n.params) do declare(name) end
  elseif n.kind=='For' then for _,name in ipairs(n.names) do declare(name) end
  elseif n.kind=='Assignment' then
   for _,target in ipairs(n.targets) do local root=chain(target);if root then writes[root]=true end end
  end
  local id=module_call(n)
  if id=='moonstone.target' then imports.target=imports.target+1
  elseif id=='moonstone.project' then imports.project=imports.project+1
  elseif id=='moonstone' then
   if parent and parent.kind=='Member' and parent.object==n and (parent.key=='target' or parent.key=='project') then imports[parent.key]=imports[parent.key]+1
   else imports.target=imports.target+2;imports.project=imports.project+2 end
  end
 end)
 for _,n in ipairs(tree.statements) do
  if n.kind=='Local' and #n.names==1 and #n.values==1 then
   local kind=imported(n.values[1]);local name=n.names[1]
   if kind and context[kind] and declared[name]==1 and not writes[name]
     and imports[kind]==1 and not declared['require'] and not writes['require'] then bindings[name]={kind=kind,value=context[kind]} end
  end
 end
 -- A root may only occur as part of a literal-key field chain. Passing the
 -- root or a child table to unknown code, shadowing it, or writing any field
 -- invalidates the entire binding. This deliberately misses some safe folds.
 walk(tree,function(n,parent)
  if n.kind=='Identifier' and bindings[n.name] then
   if not(parent and (parent.kind=='Member' or parent.kind=='Index') and parent.object==n) then bindings[n.name]=nil end
  elseif n.kind=='Member' or n.kind=='Index' then
   local outer=parent and (parent.kind=='Member' or parent.kind=='Index') and parent.object==n
   if not outer then
    local root,keys=chain(n);local binding=root and bindings[root]
    if binding then
     local value=binding.value
     for _,key in ipairs(keys) do if type(value)=='table' then value=value[key] else value=nil;break end end
     if type(value)=='table' or (binding.kind=='target' and keys[1]=='runtime' and #keys==1 and not context.runtime_known) then bindings[root]=nil end
    elseif not root then
     local root_expr=n.object;while root_expr.object do root_expr=root_expr.object end
     if root_expr.kind=='Identifier' then bindings[root_expr.name]=nil end
    end
   end
  end
 end)
 local jit_marker={}
 local globals=options.assume_runtime_globals==true
 local function runtime_global(name)
  if not globals or declared[name] or writes[name] then return false end
  if name=='_VERSION' then
   if context.target.family=='lua' then return true,'Lua '..math.floor(context.target.level/10)..'.'..context.target.level%10 end
   if context.target.family=='luajit' then return true,'Lua 5.1' end
  elseif name=='jit' then return true,context.target.family=='luajit' and jit_marker or nil end
  return false
 end
 local evaluate
 evaluate=function(n)
  if n.kind=='Literal' then
   if n.numeric and (not n.value or n.value~=math.floor(n.value) or math.abs(n.value)>9007199254740991) then return false end
   return true,n.value
  end
  if n.kind=='Paren' then return evaluate(n.value) end
  if n.kind=='Identifier' then return runtime_global(n.name) end
  if n.kind=='Member' or n.kind=='Index' then
   local root,keys=chain(n);local binding=root and bindings[root]
   if not binding then return false end
   if binding.kind=='target' and keys[1]=='runtime' and not context.runtime_known then return false end
   local value=binding.value
   for _,key in ipairs(keys) do
    if type(value)~='table' then return false end
    value=value[key]
   end
   if type(value)=='table' then return false end
   return true,value
  end
  if n.kind=='Unary' and n.op=='not' then local known,value=evaluate(n.value);if known then return true,not value end end
  if n.kind=='Binary' then
   local known,left=evaluate(n.left);if not known then return false end
   if n.op=='and' and not left then return true,left end
   if n.op=='or' and left then return true,left end
   local rhs,right=evaluate(n.right);if not rhs then return false end
   if n.op=='and' or n.op=='or' then return true,right end
   if n.op=='==' then return true,left==right elseif n.op=='~=' then return true,left~=right end
   if (type(left)=='number' and type(right)=='number') or (type(left)=='string' and type(right)=='string') then
    if n.op=='<' then return true,left<right elseif n.op=='>' then return true,left>right
    elseif n.op=='<=' then return true,left<=right elseif n.op=='>=' then return true,left>=right end
   end
  end
  if n.kind=='Call' and globals and n.callee.kind=='Identifier' and n.callee.name=='type'
   and not declared.type and not writes.type and #n.args==1 and n.args[1].kind=='Identifier' and n.args[1].name=='jit' then
   local known,value=runtime_global('jit');if known then return true,type(value) end
  end
  return false
 end
 local report={folded_fields=0,removed_branches=0}
 local render
 render=function(start,finish,root)
  local edits={}
  walk(root,function(n)
   if n.start and n.finish and n.start>=start and n.finish<=finish then
    if n.kind=='If' then
     local kept,modified={},false
     local other=n.other
     for _,clause in ipairs(n.clauses) do
      local known,value=evaluate(clause.condition)
      if known then
       modified=true
       if value then other=clause.body;break end
      else kept[#kept+1]=clause end
     end
     if modified then
      local replacement
      if #kept==0 then replacement='do\n'..(other and render(other.start,other.finish,other) or '')..'\nend'
      else
       local pieces={}
       for index,clause in ipairs(kept) do
        pieces[#pieces+1]=(index==1 and 'if ' or 'elseif ')..render(clause.condition.start,clause.condition.finish,clause.condition)..' then\n'
          ..render(clause.body.start,clause.body.finish,clause.body)
       end
       if other then pieces[#pieces+1]='else\n'..render(other.start,other.finish,other) end
       pieces[#pieces+1]='end';replacement=table.concat(pieces,'\n')
      end
      edits[#edits+1]={start=n.start,finish=n.finish,text=replacement}
      report.removed_branches=report.removed_branches+1;return false
     end
    elseif n.kind=='Member' or n.kind=='Index' or (globals and n.kind=='Identifier') then
     local known,value=evaluate(n);local text=known and quote(value)
     if text then edits[#edits+1]={start=n.start,finish=n.finish,text=text};report.folded_fields=report.folded_fields+1;return false end
    end
   end
  end)
  table.sort(edits,function(a,b)return a.start<b.start end)
  local out,cursor={},start
  for _,edit in ipairs(edits) do
   assert(edit.start>=cursor,'overlapping AST edits');out[#out+1]=source:sub(cursor,edit.start-1);out[#out+1]=edit.text;cursor=edit.finish+1
  end
  out[#out+1]=source:sub(cursor,finish);return table.concat(out)
 end
 local output=render(1,#source,tree)
 return output,report
end
return M
