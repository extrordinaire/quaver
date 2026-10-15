-- Compose distinct loader scopes. This never partitions one shared Lua module
-- graph by assumption: each static region has its own complete source inventory.
local build=require('quaver.build').build
local bundle=require('quaver.bundle').bundle
local diagnostic=require('quaver.diagnostic')
local report=require('quaver.report')
local M={}
local prefix='__quaver_regions'
local function sorted(t)local out={};for key in pairs(t)do out[#out+1]=key end;table.sort(out);return out end
local function fail(code,message,suggestion)
 diagnostic.raise(code,message,nil,1,'<regions>','Static regions use separate inventories and private module caches. They are not a security sandbox.',suggestion)
end
local function copy(t)local out={};for key,value in pairs(t)do out[key]=value end;return out end
local function snapshot(config)
 local out=copy(config)
 if type(config.modules)=='table' then out.modules=copy(config.modules) end
 for _,field in ipairs({'facades','boundaries','externals'})do
  if type(config[field])=='table' then
   out[field]={}
   for key,value in pairs(config[field])do
    if type(value)=='table' then
     value=copy(value)
     if type(value.exports)=='table' then value.exports=copy(value.exports) end
    end
    out[field][key]=value
   end
  end
 end
 return out
end
local function valid_name(name)
 return type(name)=='string' and name:match('^[%a_][%w_-]*$')~=nil
end
function M.build(options)
 if type(options)~='table' or type(options.host)~='table' or type(options.regions)~='table' then
  fail('QV301','Regional builds require host and regions configurations.','Provide a host inventory and independently owned static inventories.')
 end
 local host=snapshot(options.host)
 if type(host.modules)~='table' then fail('QV203','The dynamic host requires a complete inventory.','Supply host.modules, or use declared Ballad inputs.') end
 if host.load then fail('QV301','Regional host loading cannot escape its declared inventory.','Supply host.modules without a lazy loader.') end
 for id in pairs(host.modules)do
  if id==prefix or id:sub(1,#prefix+1)==prefix..'.' or id=='quaver-contract' or id=='quaver-report' or id=='quaver-regions' then
   fail('QV303','Host module collides with a generated artifact: '..id,'Rename the module; __quaver_regions is reserved for closed artifacts.')
  end
 end
 -- The host is retained exactly, even if its original config requested Strict.
 host.mode='conservative'
 local out={host=build(host),host_sources=host.modules,host_configuration=host,regions={},sources={},configurations={},report={schema_version=1,regions={}}}
 for name in pairs(options.regions)do if not valid_name(name) then fail('QV301','Invalid region name: '..tostring(name),'Use a single identifier without dots, slashes, or traversal components.') end end
 for _,name in ipairs(sorted(options.regions))do
  if not valid_name(name) then fail('QV301','Invalid region name: '..tostring(name),'Use a single identifier without dots, slashes, or traversal components.') end
  local ok,result,config=pcall(function()
  local config=options.regions[name]
  if type(config)~='table' then fail('QV301','Invalid region configuration: '..name,'Provide an entry and a complete modules inventory.') end
  config=snapshot(config)
  if config.mode and config.mode~='strict' then fail('QV301','Static region '..name..' requires Strict mode.','Use strict contracts, or keep these sources in the dynamic host.') end
  if config.format and config.format~='bundle' then fail('QV301','Static region '..name..' requires private bundle emission.','Keep public module files in the host inventory.') end
  if type(config.modules)~='table' or config.load then fail('QV203','Static region '..name..' requires a complete, closed inventory.','Supply modules without a lazy loader.') end
  if next(config.boundaries or {}) or next(config.externals or {}) or config.regions then
   fail('QV302','Static region '..name..' crosses an unverified runtime boundary.','Include all dependency sources; keep dynamic regions, runtime metadata, and external imports in the host.')
  end
  config.mode='strict';config.format='bundle'
  local result=build(config)
  -- Check the emitted graph too; no implicit external may enter a region.
  for _,deps in pairs(result.report.dependencies)do for _,id in ipairs(deps)do
   if not result.modules[id] then fail('QV302','Static region '..name..' imports an external module: '..id,'Include the dependency source in this region.') end
  end end
  return result,config
  end)
  if not ok then
    if type(result)~='table' or not result.code then result=diagnostic.new('QV900',tostring(result),nil,1,'<regions>','Regional compilation failed.','Check this region configuration and inputs.')end
    result.region=name;result.stage=result.stage or 'regional_validation'
    local completed={host=out.host.report,regions={}}
    for id,region in pairs(out.regions)do completed.regions[id]=region.report end
    result.completed_scopes=completed
    error(result,0)
  end
  out.regions[name]=result;out.sources[name]=config.modules;out.configurations[name]=config
  out.report.regions[name]={entry=result.entry,module=prefix..'.'..name,path=prefix..'/'..name..'.lua',
   retained=result.report.retained,removed=result.report.removed}
 end
 return out
end
function M.files(result,options,hash)
 local files={}
 local function add(path,content)
  if files[path] then fail('QV303','Generated output collision: '..path,'Rename the conflicting module or artifact.') end
  files[path]=content
 end
 for _,id in ipairs(result.host.report.retained)do
  if not id:match('^[%w_%.%-]+$') or id:find('..',1,true) then fail('QV303','Unsafe host module path: '..id,'Use ordinary dotted module identifiers.') end
  add(id:gsub('%.','/')..'.lua',result.host.modules[id])
 end
 add('quaver-contract.lua',report.render(result.host,result.host_configuration,result.host_sources,hash))
 local lines={'Quaver regional build','host: preserved '..#result.host.report.retained..' modules'}
 local index={schema_version=1,compiler_version=require('quaver.version'),regions={}}
 for _,name in ipairs(sorted(result.regions))do
  local region=result.regions[name];local path=prefix..'/'..name..'.lua'
  local source=bundle(region)
  add(path,source)
  add(prefix..'/'..name..'.contract.lua',report.render(region,result.configurations[name],result.sources[name],hash))
  index.regions[name]={entry=region.entry,module=prefix..'.'..name,path=path,
   retained=region.report.retained,removed=region.report.removed,minification=region.report.minification,bundle_bytes=#source,
   bundle_hash=hash and hash(source) or 'not_recorded'}
  lines[#lines+1]=name..': '..#region.report.retained..' retained, '..#region.report.removed..' removed, '..#source..' bundle bytes, minification '..region.report.minification.applied
 end
 add('quaver-regions.lua','return '..report.encode(index)..'\n')
 add('quaver-report.txt',table.concat(lines,'\n')..'\n')
 return files
end
return M
