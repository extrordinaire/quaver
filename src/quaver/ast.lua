-- Lua statement/expression AST, with byte spans into the original source.
-- Parsing precedes specialization: foreign grammar in a dead branch is still
-- rejected. Luau extensions are not accepted by this Lua frontend.
local lexer=require('quaver.lexer')
local literal=require('quaver.literal')
local M={}
local keywords={['and']=true,['break']=true,['do']=true,['else']=true,['elseif']=true,['end']=true,
 ['false']=true,['for']=true,['function']=true,['goto']=true,['if']=true,['in']=true,['local']=true,
 ['nil']=true,['not']=true,['or']=true,['repeat']=true,['return']=true,['then']=true,['true']=true,['until']=true,['while']=true}
local prec={['or']=1,['and']=2,['<']=3,['>']=3,['<=']=3,['>=']=3,['==']=3,['~=']=3,
 ['|']=4,['~']=5,['&']=6,['<<']=7,['>>']=7,['..']=8,['+']=9,['-']=9,['*']=10,['/']=10,['//']=10,['%']=10,['^']=12}
function M.parse(source,target)
 local ts=lexer.scan(source);local pos=1;local level=target and target.level or 55
 local function peek()return ts[pos] and ts[pos].text end
 local function take(text)
  local t=ts[pos];assert(t and (not text or t.text==text),'expected '..tostring(text)..' near '..tostring(peek()))
  pos=pos+1;return t
 end
 local goto_enabled=level>=52 or (target and target.family=='luajit')
 local function keyword(text)return keywords[text] and not(text=='goto' and not goto_enabled) end
 local function binding_name()local t=take();assert(t.kind=='name' and not keyword(t.text),'expected identifier');return t.text,{start=t.start,finish=t.finish} end
 local function name()local value=binding_name();return value end
 local function node(kind,start,fields)
  fields=fields or {};fields.kind=kind;fields.start=start;fields.finish=ts[pos-1].finish;return fields
 end
 local expression,block,statement,body
 local function list()
  local out={expression(0)};while peek()==',' do take(',');out[#out+1]=expression(0) end;return out
 end
 local function args()
  if peek()=='(' then take('(');local out=peek()~=')' and list() or {};take(')');return out end
  if peek()=='{' or (ts[pos] and ts[pos].kind=='string') then return {expression(13)} end
  error('expected call arguments',0)
 end
 local function primary()
  local t=take();local out
  if t.kind=='number' then out=node('Literal',t.start,{value=tonumber(t.text),numeric=true})
  elseif t.kind=='string' then out=node('Literal',t.start,{value=literal.value(t)})
  elseif t.text=='true' or t.text=='false' or t.text=='nil' then
   local value;if t.text=='true' then value=true elseif t.text=='false' then value=false end
   out=node('Literal',t.start,{value=value})
  elseif t.text=='...' then out=node('Vararg',t.start)
  elseif t.text=='(' then out=node('Paren',t.start,{value=expression(0)});take(')');out.finish=ts[pos-1].finish
  elseif t.text=='function' then out=body(t.start)
  elseif t.text=='{' then
   local fields={}
   while peek()~='}' do
    local key,value
    if peek()=='[' then take('[');key=expression(0);take(']');take('=');value=expression(0)
    elseif ts[pos] and ts[pos+1] and ts[pos].kind=='name' and ts[pos+1].text=='=' then key={kind='Literal',value=name()};take('=');value=expression(0)
    else value=expression(0) end
    fields[#fields+1]={key=key,value=value}
    if peek()==',' or peek()==';' then take() else break end
   end
   take('}');out=node('Table',t.start,{fields=fields})
  else assert(t.kind=='name' and not keyword(t.text),'unsupported expression near '..t.text);out=node('Identifier',t.start,{name=t.text}) end
  while true do
   if peek()=='.' then take('.');out=node('Member',out.start,{object=out,key=name()})
   elseif peek()=='[' then take('[');local key=expression(0);take(']');out=node('Index',out.start,{object=out,key=key})
   elseif peek()==':' then take(':');local key=name();local callee=node('Member',out.start,{object=out,key=key});out=node('Call',out.start,{callee=callee,args=args(),method=true})
   elseif peek()=='(' or peek()=='{' or (ts[pos] and ts[pos].kind=='string') then out=node('Call',out.start,{callee=out,args=args()})
   else break end
  end
  return out
 end
 expression=function(min)
  local out;local op=peek()
  if op=='not' or op=='#' or op=='-' or op=='~' then
   if op=='~' then assert(level>=53,'bitwise syntax needs Lua 5.3; use a variant file') end
   local start=take().start;out=node('Unary',start,{op=op,value=expression(11)})
  else out=primary() end
  while prec[peek()] and prec[peek()]>=min do
   local binary=take().text
   if binary=='//' or binary=='|' or binary=='&' or binary=='~' or binary=='<<' or binary=='>>' then
    assert(level>=53,'operator '..binary..' needs Lua 5.3; use a variant file')
   end
   local right=expression(prec[binary]+((binary=='^' or binary=='..') and 0 or 1))
   out=node('Binary',out.start,{op=binary,left=out,right=right})
  end
  return out
 end
 body=function(start,method)
  take('(');local params,param_spans={},{};if method then params[1]='self' end
  if peek()~=')' then repeat
   if peek()=='...' then take('...');break end
   local value,span=binding_name();params[#params+1]=value;param_spans[#params]=span;if peek()~=',' then break end;take(',')
  until false end
  take(')');local code=block({['end']=true});take('end');return node('Function',start,{params=params,param_spans=param_spans,body=code})
 end
 block=function(stops)
  local start=ts[pos] and ts[pos].start or #source+1;local statements={}
  while peek() and not stops[peek()] do statements[#statements+1]=statement() end
  return {kind='Block',start=start,finish=(ts[pos] and ts[pos].start or #source+1)-1,statements=statements}
 end
 statement=function()
  local start=ts[pos].start;local head=peek()
  if head==';' then take();return node('Empty',start) end
  if head=='local' then
   take('local')
   if peek()=='function' then take('function');local binding,span=binding_name();return node('LocalFunction',start,{name=binding,name_span=span,value=body(start)}) end
   local names,attributes,name_spans={},{},{}
   repeat
    local value,span=binding_name();names[#names+1]=value;name_spans[#names]=span
    if peek()=='<' then
     assert(level>=54,'local attributes need Lua 5.4; use a variant file');take('<');local attribute=name();assert(attribute=='const' or attribute=='close','unknown local attribute');take('>');attributes[#names]=attribute
    end
    if peek()~=',' then break end;take(',')
   until false
   local values={};if peek()=='=' then take('=');values=list() end
   return node('Local',start,{names=names,name_spans=name_spans,values=values,attributes=attributes})
  elseif head=='function' then
   take();local target_expr=node('Identifier',ts[pos].start,{name=name()})
   while peek()=='.' do take();target_expr=node('Member',target_expr.start,{object=target_expr,key=name()}) end
   local method=false;if peek()==':' then take();target_expr=node('Member',target_expr.start,{object=target_expr,key=name()});method=true end
   return node('Assignment',start,{targets={target_expr},values={body(start,method)}})
  elseif head=='if' then
   take();local clauses={}
   repeat local condition=expression(0);take('then');local code=block({['elseif']=true,['else']=true,['end']=true});clauses[#clauses+1]={condition=condition,body=code}
    if peek()~='elseif' then break end;take()
   until false
   local other;if peek()=='else' then take();other=block({['end']=true}) end;take('end')
   return node('If',start,{clauses=clauses,other=other})
  elseif head=='do' then take();local code=block({['end']=true});take('end');return node('Do',start,{body=code})
  elseif head=='while' then take();local condition=expression(0);take('do');local code=block({['end']=true});take('end');return node('While',start,{condition=condition,body=code})
  elseif head=='repeat' then take();local code=block({['until']=true});take('until');return node('Repeat',start,{body=code,condition=expression(0)})
  elseif head=='for' then
   take();local first,span=binding_name();local names,name_spans={first},{span};while peek()==',' do take();local value,location=binding_name();names[#names+1]=value;name_spans[#names]=location end
   local mode=take().text;assert(mode=='=' or mode=='in','expected for loop');local values=list();take('do');local code=block({['end']=true});take('end')
   return node('For',start,{names=names,name_spans=name_spans,values=values,body=code})
  elseif head=='return' then
   take();local terminator=peek()==nil or peek()==';' or peek()=='end' or peek()=='else' or peek()=='elseif' or peek()=='until'
   return node('Return',start,{values=not terminator and list() or {}})
  elseif head=='break' then take();return node('Break',start)
  elseif (head=='goto' and goto_enabled) or head=='::' then
   assert(level>=52 or (target and target.family=='luajit'),'goto syntax needs Lua 5.2 or LuaJIT; use a variant file')
   take();local label=name();if head=='::' then take('::') end;return node('Label',start,{label=label})
  else
   local values=list()
   if peek()=='=' then take();return node('Assignment',start,{targets=values,values=list()}) end
   assert(#values==1 and values[1].kind=='Call','expected assignment or call')
   return node('CallStatement',start,{value=values[1]})
  end
 end
 local tree=block({});assert(not peek(),'unexpected trailing source');tree.source=source;return tree
end
return M
