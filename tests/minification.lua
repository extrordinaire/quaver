local minifier=require('quaver.minifier')
local build=require('quaver.build').build
local report=require('quaver.report')
local lexer=require('quaver.lexer')
local count=0
local function test(name,fn)fn();count=count+1;print('PASS minification: '..name)end
local function compile(source)local f,err=(loadstring or load)(source,'@minification-test');assert(f,err);return f end
local function reject(fn)
 local ok,err=pcall(fn);assert(not ok);assert(type(err)=='table' and err.code=='QV001',tostring(err))
end
local source='-- banner\nlocal x = 1 -- trailing comment\n\nreturn 3\n'
local function strict(value)
 return build({mode='strict',entry='app',modules={app=source},minify=value})
end
test('none preserves bytes; named safe and compact preserve executed values',function()
 assert(minifier.minify(source,{level='none'})==source)
 local safe=minifier.minify(source,{level='safe'})
 local compact=minifier.minify(source,{level='compact'})
 assert(#compact<#safe and #safe<#source)
 for _,code in ipairs({source,safe,compact})do assert(compile(code)()==3)end
end)
test('booleans and standalone legacy defaults remain compatible',function()
 assert(minifier.minify(source,true)==minifier.minify(source,{level='safe'}))
 assert(minifier.minify(source,false)==source)
 assert(minifier.minify(source)==minifier.minify(source,{level='compact'}))
 assert(minifier.minify(source,{})==minifier.minify(source))
 assert(minifier.minify(source,{preserve_lines=true})==minifier.minify(source,{level='safe'}))
 assert(minifier.minify(source,{preserve_lines=false})==minifier.minify(source,{level='compact'}))
 assert(strict(true).modules.app==strict({level='safe'}).modules.app)
 assert(strict(false).modules.app==source and strict(nil).modules.app==source)
end)
test('safe preserves runtime error lines; compact explicitly trades them for size',function()
 local code='-- banner\r\nlocal x=1\r\n-- another comment\r\n\r\nerror("failure")\r\n'
 local function failure_line(text)
  local ok,err=pcall(compile(text));assert(not ok);return tostring(err):match('minification%-test:(%d+):')
 end
 assert(failure_line(code)=='5')
 assert(failure_line(minifier.minify(code,{level='safe'}))=='5')
 assert(failure_line(minifier.minify(code,{level='compact'}))=='1')
end)
test('every level preserves token spellings, literal bytes and lexical boundaries',function()
 local cases={'local x=2;return x - -1',
  'return 1 .. "x", .5, 0xff, 1e-3',
  'return [=[long -- literal\ntext]=], "--not a comment"',
  'return "escaped\\\"quote", "a\\\nb"',
  'local x=1; --[==[long\ncomment]==]\nreturn x',
  'local a=1\nlocal b=2\nreturn a,b'}
 for _,code in ipairs(cases)do
  local expected={compile(code)()};local tokens=lexer.scan(code)
  for _,level in ipairs({'none','safe','compact'})do
   local output=minifier.minify(code,{level=level});local actual={compile(output)()}
   for index,value in ipairs(expected)do assert(actual[index]==value)end
   local after=lexer.scan(output);assert(#after==#tokens)
   for index,token in ipairs(tokens)do assert(after[index].text==token.text)end
  end
 end
end)
test('invalid levels fail instead of degrading silently',function()
 for _,value in ipairs({'compact',1,{},{level='invalid'},{level='fast'},{level='safe',rename=true}})do
  reject(function()strict(value)end)
 end
 reject(function()minifier.minify(source,{level='compact',preserve_lines=true})end)
end)
test('build reports record requested and applied levels independently',function()
 for _,level in ipairs({'none','safe','compact'})do
  local result=strict({level=level});assert(result.report.minification.requested==level and result.report.minification.applied==level)
  assert(result.report.before_minify_bytes==#source and result.report.output_bytes==#result.modules.app)
  local data=compile(report.render(result))();assert(data.minification.applied==level)
 end
end)
test('Conservative mode and runtime boundaries withhold every named transformation',function()
 for _,level in ipairs({'safe','compact'})do
  for _,mode in ipairs({'conservative','strict'})do
   local result=build({mode=mode,entry='app',modules={app=source},minify={level=level},
    boundaries=mode=='strict' and {app={kind='runtime',reason='Runtime integration'}} or nil})
   assert(result.modules.app==source)
   assert(result.report.minification.requested==level and result.report.minification.applied=='none')
   local found=false;for _,note in ipairs(result.report.diagnostics)do if note.code=='QV202' then found=true end end;assert(found)
  end
 end
end)
test('Valua schemas accept named levels including mangling and reject invalid levels',function()
 local previous=package.path;package.path='../valua/src/?.lua;../valua/src/?/init.lua;'..package.path
 local v=require('valua');package.path=previous
 local schemas=require('quaver.schemas').create(v)
 for _,value in ipairs({true,false,{level='none'},{level='safe'},{level='compact'}})do
  assert(v.safe_parse(schemas.minification,value).success)
  assert(v.safe_parse(schemas.region,{entry='app',modules={app=source},minify=value}).success)
 end
 assert(v.safe_parse(schemas.minification,{level='mangle'}).success)
 assert(not v.safe_parse(schemas.minification,{level='safe',rename=true}).success)
end)
print(count..' minification tests passed')
