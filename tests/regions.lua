local regions=require('quaver.regions')
local count=0
local function test(name,fn)fn();count=count+1;print('PASS regions: '..name)end
local function rejects(fn,code)
 local ok,err=pcall(fn);assert(not ok,'expected rejection');assert(type(err)=='table' and err.code==code,tostring(err));return err
end
local function compile(source)local f,err=(loadstring or load)(source,'@regional-test');assert(f,err);return f end
local function config()
 return {host={entry='app',modules={app='return function(name)return require(name)end',plugin='return "plugin"'},
   boundaries={app={kind='runtime',reason='Runtime plugin selection'}}},
  regions={core={entry='app',minify=true,modules={app='local c=require("core");return function()return c.used()end',
   core='local c={} c.used=require("used") c.unused=require("unused") return c',
   used='return function()return "private"end',unused='return function()return "unused"end'},
   facades={core={exports={'used'}}}}}}
end
local function host_loader(files)
 local cache={}
 local load_module
 load_module=function(id)
  if cache[id]~=nil then return cache[id] end
  local source=assert(files[id:gsub('%.','/')..'.lua'],'host cannot resolve '..id)
  local f=compile(source)
  local value
  if setfenv then setfenv(f,setmetatable({require=load_module},{__index=_G}));value=f()
  else
   local environment=setmetatable({require=load_module},{__index=_G})
   value=assert(load(source,'@host-module','t',environment))()
  end
  cache[id]=value==nil and true or value;return cache[id]
 end
 return load_module
end
test('runtime host is preserved while a separate static artifact is shaken',function()
 local options=config();local result=regions.build(options);local files=regions.files(result,options)
 for id,source in pairs(options.host.modules)do assert(files[id..'.lua']==source)end
 assert(result.host.report.preserved and not result.regions.core.modules.unused)
 assert(files['__quaver_regions/core.lua'] and not files['used.lua'])
 local require_host=host_loader(files)
 local app=require_host('app')
 assert(app('plugin')=='plugin')
 assert(app('__quaver_regions.core')()=='private')
 assert(not pcall(app,'used'),'private source escaped its loader scope')
end)
test('private region caches ignore host module identities and mutable exports',function()
 local options=config();options.host.modules.used='return function()return "host"end'
 local result=regions.build(options);local files=regions.files(result,options)
 local require_host=host_loader(files)
 assert(require_host('app')('used')()=='host')
 assert(require_host('app')('__quaver_regions.core')()=='private')
 local previous=package.loaded.used;package.loaded.used=function()return 'poisoned'end
 local value=compile(files['__quaver_regions/core.lua'])()()
 package.loaded.used=previous;assert(value=='private')
end)
test('scopes can reuse logical module names without sharing loading state',function()
 local options=config();options.regions.second={entry='app',modules={app='return function()return "second"end'}}
 local files=regions.files(regions.build(options),options)
 assert(compile(files['__quaver_regions/core.lua'])()()=='private')
 assert(compile(files['__quaver_regions/second.lua'])()()=='second')
end)
test('regions cannot import host modules or gain external assumptions',function()
 local options=config();options.regions.core.modules.app='return require("host_only")';options.host.modules.host_only='return {}'
 local err=rejects(function()regions.build(options)end,'QV103');assert(err.region=='core' and tostring(err):find('Region core',1,true))
 for _,field in ipairs({'boundaries','externals','load'})do
  local c=config();c.regions.core[field]=field=='load' and function()return 'return {}'end or {dynamic=true}
  rejects(function()regions.build(c)end,field=='load' and 'QV203' or 'QV302')
 end
end)
test('strict diagnostics cannot be suppressed by a neighboring dynamic boundary',function()
 local options=config();options.regions.core.modules.unused='external_state=true;return function()end'
 local err=rejects(function()regions.build(options)end,'QV105');assert(err.region=='core')
end)
test('ambiguous output ownership and traversal names are rejected',function()
 for _,name in ipairs({'../outside','a.b','a/b'})do
  local options=config();options.regions[name]=options.regions.core
  rejects(function()regions.build(options)end,'QV301')
 end
 local options=config();options.host.modules['__quaver_regions.core']='return {}'
 rejects(function()regions.build(options)end,'QV303')
end)
test('regional reports and outputs are deterministic and configs are not mutated',function()
 local options=config();local before=options.regions.core.modules.unused
 local first=regions.files(regions.build(options),options);local second=regions.files(regions.build(options),options)
 for path,source in pairs(first)do assert(source==second[path],path)end
 assert(options.host.mode==nil and options.regions.core.mode==nil and options.regions.core.modules.unused==before)
 local index=compile(first['quaver-regions.lua'])();assert(index.regions.core.module=='__quaver_regions.core')
 local contract=compile(first['__quaver_regions/core.contract.lua'])();assert(contract.mode=='strict' and contract.proofs.unused.initializer=='verified')
end)
test('provenance snapshots cannot be changed by later caller mutations',function()
 local options=config();local result=regions.build(options)
 options.host.modules.plugin='return "changed"'
 options.regions.core.modules.unused='return "changed"'
 options.regions.core.facades.core.exports[1]='unused'
 local files=regions.files(result,options)
 assert(files['plugin.lua']=='return "plugin"')
 assert(result.sources.core.unused=='return function()return "unused"end')
 local contract=compile(files['__quaver_regions/core.contract.lua'])()
 assert(contract.profiles.core[1]=='used')
end)
test('Valua schema validates regional declarations independently of proof checks',function()
 local previous=package.path;package.path='../valua/src/?.lua;../valua/src/?/init.lua;'..package.path
 local v=require('valua');package.path=previous
 local schema=require('quaver.schemas').create(v).region
 assert(v.safe_parse(schema,config().regions.core).success)
 assert(not v.safe_parse(schema,{entry='app',modules={},externals={host=true}}).success)
end)
print(count..' regional tests passed')
