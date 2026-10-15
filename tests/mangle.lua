local minifier=require('quaver.minifier')
local build=require('quaver.build').build
local count=0
local function test(name,fn)fn();count=count+1;print('PASS mangle: '..name)end
local function pack(...)return {n=select('#',...),...}end
local function execute(source)
 local env=setmetatable({a=40,newly_declared=9,call_me=function()return 42 end},{__index=_G})
 local f,err
 if setfenv then f,err=loadstring(source);if f then setfenv(f,env)end
 else f,err=load(source,'@mangle-test','t',env)end
 assert(f,err);return pack(f())
end
local function equal(a,b)
 if type(a)~=type(b)then return false end
 if type(a)~='table'then return a==b end
 for key,value in pairs(a)do if not equal(value,b[key])then return false end end
 for key in pairs(b)do if a[key]==nil then return false end end
 return true
end
local function differential(source,target)
 local output=minifier.minify(source,{level='mangle'},target)
 assert(equal(execute(source),execute(output)),output)
 assert(output==minifier.minify(source,{level='mangle'},target),'nondeterministic mangling')
 return output
end
test('closures retain the binding visible at their declaration',function()
 differential('local long_count=10;local get_count=function()return long_count end;local long_count=20;return get_count(),long_count')
 differential('local getter=function()return newly_declared end;local newly_declared=17;return getter(),newly_declared')
end)
test('all local RHS expressions see the old scope',function()
 differential('local left_value,right_value=3,7;local left_value,right_value=right_value,left_value;return left_value,right_value')
 differential('local call_me=function(n)if n==0 then return 99 end;return call_me(0)end;return call_me(1)')
 differential('local outer_value=10;do local outer_value=outer_value+1;return outer_value end')
end)
test('local functions bind recursively before their bodies',function()
 differential('local function factorial(number)if number<=1 then return 1 end;return number*factorial(number-1)end;return factorial(6)')
 differential('local even,odd;even=function(n)return n==0 or odd(n-1)end;odd=function(n)return n~=0 and even(n-1)end;return even(6),odd(6)')
end)
test('varargs, duplicate binding names and global function declarations retain behavior',function()
 differential('local function forward(long_parameter,...)local argument_count=select("#",...);return long_parameter,argument_count,... end;return forward("x",nil,3)')
 differential('local repeated_name,repeated_name=1,2;return repeated_name')
 differential('local function choose(repeated_name,repeated_name)return repeated_name end;return choose(1,2)')
 local output=differential('local captured_value=7;function public_handler(long_parameter)return captured_value+long_parameter end;return public_handler(5)')
 assert(output:find('function public_handler(',1,true))
end)
test('method syntax retains implicit self and explicit shadowing',function()
 local output=differential('local object={amount=7};function object:method(extra)local total=self.amount+extra;return total end;return object:method(5),object.amount')
 assert(output:find(':method',1,true)and output:find('self.amount',1,true))
 differential('local object={};function object:method(self)return self end;return object:method(99)')
 differential('local object={};local method_result=7;function object.method()return method_result end;return object.method()')
end)
test('numeric and generic loop variables have separate lexical scopes',function()
 differential('local loop_index=3;local functions={};for loop_index=loop_index,5 do local captured=loop_index;functions[#functions+1]=function()return captured end end;return loop_index,functions[1](),functions[3]()')
 differential('local total=0;for long_index,long_value in ipairs({2,4,6})do total=total+long_index*long_value end;return total')
end)
test('repeat conditions see body locals; other blocks do not leak',function()
 differential('local count=0;repeat local previous=count;count=count+1 until previous>=2;return count')
 differential('local outer=7;while outer<9 do local inner=outer;outer=inner+1 end;if outer==9 then local inner=2;outer=outer+inner else local inner=3;outer=outer-inner end;return outer')
end)
test('global names, public fields, literals and labels are preserved',function()
 local output=differential('local long_name=a+2;local object={long_name=long_name,text="long_name"};return object.long_name,object.text,a')
 assert(output:find('long_name=',1,true)and output:find('"long_name"',1,true))
 if _VERSION~='Lua 5.1' or jit then
  local labelled=differential('local total_count=0;::again::total_count=total_count+1;if total_count<3 then goto again end;return total_count',{level=52})
  assert(labelled:find('::again::',1,true)and labelled:find('goto again',1,true))
 end
end)
test('short names are never lengthened and generated names cannot capture globals',function()
 differential('local a=2;local long_value=3;local getter=function()return a+long_value end;do local long_value=9 end;return getter(),a')
 assert(minifier.minify('local x=1;return x',{level='mangle'})=='local x=1;return x')
end)
test('environment and closing attributes retain runtime behavior',function()
 if _VERSION~='Lua 5.1' then
  local output=differential('local _ENV={value=4};local long_value=3;return value+long_value,_ENV.value',{level=52})
  assert(output:find('_ENV',1,true))
 end
 if _VERSION=='Lua 5.4' or _VERSION=='Lua 5.5'then
  differential('local constant_value <const> = 7;return constant_value',{level=54})
  differential('local closed_count=0;do local resource <close> = setmetatable({},{__close=function()closed_count=closed_count+1 end})end;return closed_count',{level=54})
 end
end)
test('reflection is diagnosed; ordinary local shadowing is allowed',function()
 for _,source in ipairs({'return debug.getlocal(1,1)','return require("debug")','return getfenv()','return load("return 1")','return package.loaded','return _G.debug'})do
  local ok,err=pcall(minifier.minify,source,{level='mangle'})
  assert(not ok and type(err)=='table'and err.code=='QV111',tostring(err))
 end
 differential('local debug={value=3};return debug.value')
 differential('local require=function(name)return name end;return require("debug")')
end)
test('Strict builds apply mangling but Conservative mode withholds it',function()
 local source='local long_value=42;return function()return long_value end'
 local result=build({mode='strict',entry='app',modules={app=source},minify={level='mangle'}})
 assert(result.report.minification.applied=='mangle' and #result.modules.app<#source)
 local f=assert((loadstring or load)(result.modules.app))();assert(f()==42)
 local preserved=build({entry='app',modules={app=source},minify={level='mangle'}})
 assert(preserved.modules.app==source and preserved.report.minification.applied=='none')
 local ok,err=pcall(build,{mode='strict',entry='app',modules={app='return function()return package.loaded end'},minify={level='mangle'},paths={app='src/app.lua'}})
 assert(not ok and err.code=='QV111' and err.path=='src/app.lua')
end)
test('generated nested closures exercise multiple lexical binding shapes',function()
 for depth=1,30 do
  local statements={'local long_value=1;local callbacks={}'}
  for index=1,depth do
   statements[#statements+1]='do local long_value=long_value+'..index..';callbacks['..index..']=function()return long_value end;'
  end
  for _=1,depth do statements[#statements+1]='end;'end
  statements[#statements+1]='local total=0;for _,callback in ipairs(callbacks)do total=total+callback()end;return total,long_value'
  differential(table.concat(statements))
 end
end)
print(count..' mangling tests passed')
