-- Test the actual canonical module from the unpushed Moonstone branch.
package.path='../moonstone/src/core/assets/lua/?.lua;'..package.path
local variants=require('moonstone.variants')
local flavors=require('quaver.flavors')
local specialize=require('quaver.specialize').specialize
local parser=require('quaver.ast')
local function build(options) options.mode='strict';return require('quaver.build').build(options) end
local host={id='lua54-aarch64-macos',family='lua',level=54,os='macos',arch='aarch64',runtime={name='lua',version='5.4.9',abi='5.4'}}
local project={name='example',version='1.2.3',kind='lib',dependencies={{name='moonstone/valua',version='0.3.4',role='runtime'}}}
local count=0
local function test(name,fn)fn();count=count+1;print('PASS flavor: '..name)end
local function context(id)return flavors.context({host_target=host,flavor=id,project=project,variants=variants,getenv=function()return nil end})end
local function rejects(fn,needle)local ok,err=pcall(fn);assert(not ok,'expected rejection');assert(tostring(err):find(needle,1,true),tostring(err))end
local function execute(source,target)
 local previous={target=package.loaded['moonstone.target'],project=package.loaded['moonstone.project'],moonstone=package.loaded.moonstone}
 package.loaded['moonstone.target']=target;package.loaded['moonstone.project']=project;package.loaded.moonstone={target=target,project=project}
 local f=assert((loadstring or load)(source));local value=f()
 package.loaded['moonstone.target']=previous.target;package.loaded['moonstone.project']=previous.project;package.loaded.moonstone=previous.moonstone
 return value
end
test('host identity is preserved; cross target never inherits runtime',function()
 local same=context(host.id);assert(same.target==host and same.runtime_known)
 local override=flavors.context({host_target=host,flavor=host.id,variants=variants,getenv=function()return 'lua51-x86_64-linux' end});assert(override.target.level==51)
 local cross=context('lua51-x86_64-linux');assert(cross.target.family=='lua' and cross.target.level==51)
 assert(cross.target.os=='linux' and cross.target.arch=='x86_64');assert(not cross.runtime_known and cross.target.runtime==nil)
 assert(context('luajit-x86_64-linux').target.level==51)
 assert(context('luau-aarch64-windows').target.family=='luau')
 rejects(function()context('lua56-x86_64-linux')end,'invalid MOONSTONE_TARGET')
end)
test('Moonstone selects variants before any foreign syntax is parsed',function()
 local files={['app.lua']='return "base"',['app@lua51.lua']='return "lua51"',
  ['app@lua54.lua']='local x <const> = 54; return x',['unused@luau.lua']='type X = impossible: this is not Lua',
  ['mail@example.lua']='return "ordinary"'}
 local selected,paths=flavors.select(files,context('lua51-x86_64-linux'))
 assert(paths.app=='app@lua51.lua');assert(selected.unused==nil);assert(selected['mail@example'])
 local result=build({entry='app',modules=selected,target_context=context('lua51-x86_64-linux')})
 assert(execute(require('quaver.bundle').bundle(result),context('lua51-x86_64-linux').target)=='lua51')
 local jit=flavors.select({['a@lua51.lua']='fallback',['a@luajit.lua']='exact'},context('luajit-x86_64-linux'));assert(jit.a=='exact')
 local luau=flavors.select({['a.lua']='base',['a@lua51.lua']='wrong'},context('luau-x86_64-linux'));assert(luau.a=='base')
 rejects(function()flavors.select({['a@lua54.lua']='a',['a@macos.lua']='b'},context(host.id))end,'ambiguous')
 rejects(function()flavors.select({['a@macos@lua54.lua']='a'},context(host.id))end,'order')
end)
test('target and project fields fold and constant branches preserve scopes',function()
 local source=[[local t=require('moonstone.target')
local p=require('moonstone.project')
local name='outer'
if t.level >= 53 then
 local name=p.name
 if t.os ~= 'windows' then return {name=name,version=p.version,dependency=p.dependencies[1].name,family=t.family} end
else error('unreachable') end]]
 local output,report=specialize(source,context(host.id))
 assert(report.removed_branches==2);assert(not output:find('unreachable',1,true))
 local a,b=execute(source,host),execute(output,host)
 for key,value in pairs(a) do assert(value==b[key]) end
 assert(output:find('"example"',1,true));assert(output:find('"moonstone/valua"',1,true))
end)
test('constant elseif arms prune around unknown runtime conditions',function()
 local source=[[local t=require('moonstone.target')
if t.level<53 then error('unreachable old')
elseif runtime_predicate() then return 'runtime'
elseif t.os=='macos' then return 'mac'
else error('unreachable other') end]]
 local out,report=specialize(source,context(host.id));assert(report.removed_branches==1)
 assert(not out:find('unreachable',1,true));assert(out:find('runtime_predicate',1,true))
 local previous=_G.runtime_predicate
 _G.runtime_predicate=function()return true end;assert(execute(out,host)=='runtime')
 _G.runtime_predicate=function()return false end;assert(execute(out,host)=='mac')
 _G.runtime_predicate=previous
end)
test('cross runtime reads stay unknown while flavor fields fold',function()
 local source=[[local t=require('moonstone.target')
if t.runtime.name=='lua' then return t.family else return t.os end]]
 local output,report=specialize(source,context('lua51-x86_64-linux'))
 assert(output:find('t.runtime.name',1,true));assert(report.removed_branches==0)
 assert(output:find('"lua"',1,true) and output:find('"linux"',1,true))
 local same=specialize(source,context(host.id));assert(not same:find('t.runtime.name',1,true))
end)
test('reassignment, shadowing, escaping and aliases forbid folding',function()
 local snippets={
  "local t=require('moonstone.target');t={level=51};return t.level",
  "local t=require('moonstone.target');t.level=51;return t.level",
  "local t=require('moonstone.target');mutate(t);return t.level",
  "local t=require('moonstone.target');local function f(t)return t.level end;return t.level",
  "local t=require('moonstone.target');local runtime=t.runtime;mutate(runtime);return t.level",
  "local t=require('moonstone.target');local other=require('moonstone.target');other.level=51;return t.level",
  "local require=function()return {}end;local t=require('moonstone.target');return t.level",
  "local t=require('moonstone.target');return t[key]",
 }
 for _,source in ipairs(snippets) do local output,report=specialize(source,context(host.id));assert(output==source,source.." -> "..output);assert(report.folded_fields==0) end
end)
test('direct moonstone facade binding and safe closure reads are supported',function()
 local source=[[local t=require('moonstone').target
return function() if t.family=='lua' then return t.level else return 0 end end]]
 local output,report=specialize(source,context(host.id));assert(report.removed_branches==1);assert(execute(output,host)()==54)
end)
test('foreign syntax is rejected even in a constant false branch',function()
 local cross=context('lua51-x86_64-linux')
 rejects(function()specialize('if false then local x <const> = 1 end',cross)end,'variant file')
 rejects(function()specialize('if false then return 4 // 2 end',cross)end,'variant file')
 rejects(function()specialize('if false then goto label end',cross)end,'assignment or call')
 rejects(function()specialize('type X = number',context('luau-x86_64-linux'))end,'assignment or call')
 parser.parse('local goto=1;return goto',cross.target)
end)
test('runtime global specialization is opt-in and respects shadowing',function()
 local source="if _VERSION=='Lua 5.1' and type(jit)=='table' and jit~=nil then return 1 else return 2 end"
 local _,unchanged=specialize(source,context('luajit-x86_64-linux'));assert(unchanged.removed_branches==0)
 local out,report=specialize(source,context('luajit-x86_64-linux'),{assume_runtime_globals=true});assert(report.removed_branches==1);assert(execute(out,host)==1)
 local shadow="local jit=nil;if jit~=nil then return 1 else return 2 end"
 local same,stats=specialize(shadow,context(host.id),{assume_runtime_globals=true});assert(same==shadow and stats.removed_branches==0)
end)
test('AST handles real Valua modules and captures boolean/nested control flow',function()
 local f=assert(io.popen('find ../valua/src/valua -type f -name "*.lua"'))
 for path in f:lines() do
  local input=assert(io.open(path,'rb'));local source=input:read('*a');input:close()
  local ok,err=pcall(parser.parse,source,host);assert(ok,path..': '..tostring(err))
 end
 assert(f:close())
 local output=specialize('if false==nil then return "wrong" elseif not false then return "right" end',context(host.id))
 assert(execute(output,host)=='right')
end)
print(count..' flavor tests passed')
return count
