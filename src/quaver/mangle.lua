-- Lexical alpha-renaming only. Bindings receive distinct generated names so
-- disjoint scopes and captured upvalues never accidentally share an identity.
local ast=require('quaver.ast')
local lexer=require('quaver.lexer')
local diagnostic=require('quaver.diagnostic')
local M={}
local reflective={debug=true,_G=true,getfenv=true,setfenv=true,load=true,loadstring=true,loadfile=true,dofile=true,package=true}
function M.mangle(source,target)
 local ok,tree=pcall(ast.parse,source,target)
 if not ok then diagnostic.raise('QV101','Cannot analyze scopes for mangling: '..tostring(tree),source,1,'<minifier>',
  'Mangling requires supported Lua syntax with explicit lexical bindings.','Use compact minification, or supply a supported Lua target.') end
 local reserved,bindings,edits={},{},{}
 for _,token in ipairs(lexer.scan(source))do if token.kind=='name' then reserved[token.text]=true end end
 -- Reserve every Lua keyword, even one absent from this particular program.
 for word in ('and break do else elseif end false for function goto if in local nil not or repeat return then true until while'):gmatch('%S+')do reserved[word]=true end
 local function scope(parent)return {parent=parent,bindings={}}end
 local function resolve(env,name)
  while env do if env.bindings[name] then return env.bindings[name] end;env=env.parent end
 end
 local function declare(env,name,span)
  local binding={name=name,spans={},fixed=name=='_ENV' or span==nil}
  if span then binding.spans[1]=span end
  bindings[#bindings+1]=binding;env.bindings[name]=binding
 end
 local function identifier(node,env)
  local binding=resolve(env,node.name)
  if binding then binding.spans[#binding.spans+1]={start=node.start,finish=node.finish}
  elseif reflective[node.name] then
   diagnostic.raise('QV111','Cannot mangle code using reflective runtime access: '..node.name,source,node.start,'<minifier>',
    'Local and upvalue names may be observed or code may be loaded dynamically.','Use compact minification for this code, or keep it in the preserved dynamic host.')
  end
 end
 local expression,block,statement
 expression=function(node,env)
  if not node then return end
  local kind=node.kind
  if kind=='Identifier' then identifier(node,env)
  elseif kind=='Function' then
   local child=scope(env)
   for index,name in ipairs(node.params)do declare(child,name,node.param_spans[index])end
   block(node.body,child)
  elseif kind=='Member' then expression(node.object,env)
  elseif kind=='Index' then expression(node.object,env);expression(node.key,env)
  elseif kind=='Call' then
   local callee=node.callee
   if callee.kind=='Identifier' and callee.name=='require' and not resolve(env,'require') and node.args[1]
    and node.args[1].kind=='Literal' and (node.args[1].value=='debug' or node.args[1].value=='package') then
    diagnostic.raise('QV111','Reflective modules cannot be analyzed for mangling.',source,node.start,'<minifier>',
     'An aliased debug or package import can expose renamed bindings.','Use compact minification or a preserved runtime boundary.')
   end
   expression(callee,env);for _,value in ipairs(node.args)do expression(value,env)end
  elseif kind=='Table' then for _,field in ipairs(node.fields)do expression(field.key,env);expression(field.value,env)end
  elseif kind=='Binary' then expression(node.left,env);expression(node.right,env)
  elseif kind=='Unary' or kind=='Paren' then expression(node.value,env)
  elseif kind~='Literal' and kind~='Vararg' then error('unhandled expression '..tostring(kind),0)end
 end
 statement=function(node,env)
  local kind=node.kind
  if kind=='Local' then
   -- All initializer expressions, including function bodies, see the old
   -- environment. New locals become visible only after the entire RHS.
   for _,value in ipairs(node.values)do expression(value,env)end
   for index,name in ipairs(node.names)do declare(env,name,node.name_spans[index])end
  elseif kind=='LocalFunction' then declare(env,node.name,node.name_span);expression(node.value,env)
  elseif kind=='Assignment' then
   for _,value in ipairs(node.targets)do expression(value,env)end
   for _,value in ipairs(node.values)do expression(value,env)end
  elseif kind=='CallStatement' then expression(node.value,env)
  elseif kind=='Return' then for _,value in ipairs(node.values)do expression(value,env)end
  elseif kind=='Do' then block(node.body,scope(env))
  elseif kind=='While' then expression(node.condition,env);block(node.body,scope(env))
  elseif kind=='Repeat' then local child=scope(env);block(node.body,child);expression(node.condition,child)
  elseif kind=='For' then
   for _,value in ipairs(node.values)do expression(value,env)end
   local child=scope(env)
   for index,name in ipairs(node.names)do declare(child,name,node.name_spans[index])end
   block(node.body,child)
  elseif kind=='If' then
   for _,clause in ipairs(node.clauses)do expression(clause.condition,env);block(clause.body,scope(env))end
   if node.other then block(node.other,scope(env))end
  elseif kind~='Empty' and kind~='Break' and kind~='Label' then error('unhandled statement '..tostring(kind),0)end
 end
 block=function(node,env)for _,value in ipairs(node.statements)do statement(value,env)end end
 block(tree,scope(nil))
 local alphabet='abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ'
 local tail=alphabet..'0123456789'
 local index=0
 local function candidate()
  while true do
   local number=index;local name=alphabet:sub(number%52+1,number%52+1);number=math.floor(number/52)
   while number>0 do number=number-1;name=name..tail:sub(number%62+1,number%62+1);number=math.floor(number/62)end
   if not reserved[name] then return name end
   index=index+1
  end
 end
 local renamed=0
 for _,binding in ipairs(bindings)do
  if not binding.fixed then
   local name=candidate()
   if #name<#binding.name then
    renamed=renamed+1;reserved[name]=true;index=index+1
    for _,span in ipairs(binding.spans)do edits[#edits+1]={start=span.start,finish=span.finish,text=name}end
   end
  end
 end
 table.sort(edits,function(a,b)return a.start<b.start end)
 local out,cursor={},1
 for _,edit in ipairs(edits)do
  assert(edit.start>=cursor,'overlapping binding spans')
  out[#out+1]=source:sub(cursor,edit.start-1);out[#out+1]=edit.text;cursor=edit.finish+1
 end
 out[#out+1]=source:sub(cursor)
 return table.concat(out),{renamed=renamed,bindings=#bindings}
end
return M
