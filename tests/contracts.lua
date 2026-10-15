local build=require('quaver.build').build
local bundle=require('quaver.bundle').bundle
local minify=require('quaver.minifier').minify
local report=require('quaver.report')
local count=0
local function test(name,fn)fn();count=count+1;print('PASS contract: '..name)end
local function rejects(fn,code,line)
 local ok,err=pcall(fn);assert(not ok,'expected rejection');assert(type(err)=='table' and err.code==code,tostring(err))
 assert(err.suggestion~='');if line then assert(err.line==line,tostring(err)) end;return err
end
local function strict(modules,facades)return build({mode='strict',entry='app',modules=modules,facades=facades})end
local modules={app='local v=require("lib");return function() return v.used() end',
 lib='local v={}\nv.used=require("used")\nv.unused=require("unused")\nreturn v',
 used='return function()return 42 end',unused='return function()return 0 end'}
local profile={lib={exports={'used'}}}
test('ordinary dynamic programs preserve every supplied byte',function()
 local sources={app='return require(runtime_name)',plugin='debug.getinfo(1); return package.loaded',unused='-- keep me\nreturn 2'}
 local result=build({entry='app',modules=sources,minify=true})
 for id,source in pairs(sources) do assert(result.modules[id]==source) end
 assert(#result.report.removed==0 and result.report.preserved)
 rejects(function()bundle(result)end,'QV110')
end)
test('lazy loading cannot pretend to enumerate a dynamic inventory',function()
 rejects(function()build({entry='app',load=function()return 'return 1'end})end,'QV203')
end)
test('strict proves initializers without a purity assertion',function()
 local result=strict(modules,profile)
 assert(not result.modules.unused and result.report.proofs.unused.initializer=='verified')
 local value=assert((loadstring or load)(bundle(result)))()();assert(value==42)
end)
test('a purity flag cannot hide global writes',function()
 local sources={};for id,source in pairs(modules)do sources[id]=source end
 sources.unused='external_state=1\nreturn function() end'
 rejects(function()strict(sources,{lib={pure=true,exports={'used'}}})end,'QV105',1)
end)
test('runtime registration has a contextual location',function()
 local err=rejects(function()strict({app='local m={}\n\n\n\n\n\nfunction m.register(k,v) m[k]=v end\nreturn m'})end,'QV104',7)
 assert(tostring(err):find('app.lua:7:',1,true))
end)
test('escaped, inline, shadowed and omitted export access fail',function()
 for _,source in ipairs({'local v=require("lib");return v',
  'return require("lib").used',
  'local v=require("lib");return function(v)return v.used end'})do
  local sources={};for id,code in pairs(modules)do sources[id]=code end;sources.app=source
  rejects(function()strict(sources,profile)end,'QV104')
 end
 local sources={};for id,code in pairs(modules)do sources[id]=code end
 sources.app='local v=require("lib");return function()return v.unused()end'
 rejects(function()strict(sources,profile)end,'QV107')
end)
test('declared runtime boundaries preserve behavior without granting proofs',function()
 local sources={app='return require(name)',plugins='return {}'}
 local options={mode='strict',entry='app',modules=sources,boundaries={plugins={kind='runtime',reason='Runtime-discovered plugins'}}}
 local result=build(options);assert(result.report.preserved and next(result.report.proofs)==nil)
 for id,code in pairs(sources)do assert(result.modules[id]==code)end
 rejects(function()bundle(result)end,'QV110')
 rejects(function()build({entry='app',modules=sources,boundaries={plugins={pure=true}}})end,'QV001')
end)
test('unproven table construction and closing effects cannot be discarded',function()
 for _,source in ipairs({'local v={[nil]=1};return v',
  'local v <close> = {};return {}',
  'local a,b={},a.missing;return {}',
  'local t={};t.child.value=1;return t'})do
  local sources={};for id,code in pairs(modules)do sources[id]=code end;sources.unused=source
  rejects(function()strict(sources,profile)end,'QV105')
 end
end)
test('other importers cannot invalidate plain-table initializer proofs',function()
 local sources={app='require("mutator");local v=require("lib");return function()return v.used()end',
  mutator='local shared=require("shared");setmetatable(shared,{__index=function()external_effect()end});return {}',
  shared='return {}',used='return function()return 1 end',
  lib='local v={} v.used=require("used") v.unused=require("shared").missing return v'}
 rejects(function()strict(sources,profile)end,'QV104')
end)
test('facade aliases cannot hide an imported exports-table escape',function()
 local sources={app='local v=require("lib");return function()return mutate(v.alias)end',
  lib='local v={} v.module=require("shared") v.alias=v.module v.unused=require("shared").missing return v',shared='return {}'}
 rejects(function()strict(sources,{lib={exports={'alias'}}})end,'QV104')
end)
test('strict minification keeps runtime error line numbers',function()
 local source='-- banner\nlocal value=1\n-- comment\n\nerror("same line")\n'
 local function error_line(code)local f=assert((loadstring or load)(code,'@line-test'));local ok,err=pcall(f);assert(not ok);return tostring(err):match('line%-test:(%d+):')end
 assert(error_line(source)==error_line(minify(source,{preserve_lines=true})))
end)
test('contract reports are stable data without absolute paths',function()
 local first=strict(modules,profile);local second=strict(modules,profile)
 local a=report.render(first,{facades=profile});local b=report.render(second,{facades=profile})
 assert(a==b)
 local record=assert((loadstring or load)(a))();assert(record.mode=='strict' and record.proofs.unused.initializer=='verified')
 assert(record.hash_algorithm=='not_recorded')
end)
test('strictness cannot authorize assumed runtime globals',function()
 rejects(function()build({mode='strict',entry='app',modules={app='return 1'},assume_runtime_globals=true})end,'QV108')
end)
test('Valua validates declarations but does not certify effects',function()
 local previous=package.path;package.path='../valua/src/?.lua;../valua/src/?/init.lua;'..package.path
 local v=require('valua');package.path=previous
 local schemas=require('quaver.schemas').create(v)
 assert(v.safe_parse(schemas.contracts,{mode='strict',facades=profile}).success)
 assert(not v.safe_parse(schemas.contracts,{mode='strict',boundaries={plugins={kind='runtime',reason=''}}}).success)
 assert(not v.safe_parse(schemas.contracts,{mode='strict',facades={lib={exports={'used'},pure=true}}}).success)
end)
print(count..' contract tests passed')
