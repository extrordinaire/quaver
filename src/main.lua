local directory=(arg[0] or ''):match('^(.*[/\\])') or './'
package.path=directory..'?.lua;'..directory..'?/init.lua;'..package.path
local build=require('quaver.build').build
local bundle=require('quaver.bundle').bundle
local version=require('quaver.version')
if arg[1]=='--version' then print(version);return end
if arg[1]~='build' or not arg[2] or not arg[3] or arg[4] then
  io.stderr:write('Usage: quaver build config.lua output-path\n');os.exit(2)
end
local function write_files(directory,files)
 local function quote(value)return "'"..value:gsub("'", "'\"'\"'").."'" end
 local paths={};for path in pairs(files)do paths[#paths+1]=path end;table.sort(paths)
 for _,relative in ipairs(paths)do
  local path=directory..'/'..relative
  local ok=os.execute('mkdir -p '..quote(path:match('^(.*)/')));assert(ok==true or ok==0,'cannot create output directory')
  local f=assert(io.open(path,'wb'));assert(f:write(files[relative]));f:close()
 end
end
local failure_path=arg[3]..'.failure.lua'
local last_result
local function write_path(path,bytes)
 local directory=path:match("^(.*)/") or "."
 write_files(directory,{[path:match("([^/]+)$")]=bytes})
end
local function run()
local config=assert(loadfile(arg[2]))()
assert(type(config)=='table','config must return a table')
if config.failure_report~=nil then failure_path=config.failure_report end
if config.host or config.regions then
 if config.format and config.format~='files' then
  require('quaver.diagnostic').raise('QV301','Regional CLI builds emit a directory.',nil,1,arg[2],'A host and its closed artifacts have multiple outputs.','Use format="files", or omit format.')
 end
 local compiler=require('quaver.regions')
 local result=compiler.build(config)
 last_result=result
 local files=compiler.files(result,config)
 if config.trace then
  local trace={host=result.host.trace,regions={}}
  for name,region in pairs(result.regions)do trace.regions[name]=region.trace end
  files['quaver-trace.lua']='return '..require('quaver.report').encode(trace)..'\n'
 end
 write_files(arg[3],files)
 for _,note in ipairs(result.host.report.diagnostics)do io.stderr:write(tostring(note),'\n')end
 local names={};for name in pairs(result.regions)do names[#names+1]=name end;table.sort(names)
 for _,name in ipairs(names)do
  local region=result.regions[name]
  print('Region '..name..': '..#region.report.retained..' retained, '..#region.report.removed..' removed')
 end
 print('Host: preserved '..#result.host.report.retained..' modules')
 return
end
local flavors=require('quaver.flavors')
local context=flavors.context(config)
config.target_context=context
local roots=config.roots or {'src'}
config.paths=config.paths or {}
config.load=function(id)
  local relative=id:gsub('%.','/')
  for _,root in ipairs(roots) do
    if context then
      local chosen=context.variants.resolve(id,context.target,root..'/?.lua;'..root..'/?/init.lua')
      if chosen then config.paths[id]=chosen;local f=assert(io.open(chosen,'rb'));local source=f:read('*a');f:close();return source end
    end
    for _,suffix in ipairs({'.lua','/init.lua'}) do
    local f=io.open(root..'/'..relative..suffix,'rb')
    if f then config.paths[id]=root..'/'..relative..suffix;local source=f:read('*a');f:close();return source end
  end end
end
local result=build(config)
last_result=result
if context then print('Target: '..context.target.id..' (runtime '..(context.runtime_known and 'known' or 'unknown')..')') end
local bytes=''
if config.format=='bundle' then
 bytes=bundle(result)
 local f=assert(io.open(arg[3],'wb'));assert(f:write(bytes));f:close()
else
 assert(config.format==nil or config.format=='files','format must be files or bundle')
 local files={}
 for _,id in ipairs(result.report.retained) do
  assert(id:match('^[%w_%.%-]+$') and not id:find('..',1,true),'unsafe output module id')
  files[id:gsub('%.','/')..'.lua']=result.modules[id]
 end
 write_files(arg[3],files)
end
if config.trace then write_path(config.format=='bundle' and arg[3]..'.trace.lua' or arg[3]..'/quaver-trace.lua','return '..require('quaver.report').encode(result.trace)..'\n') end
for _,note in ipairs(result.report.diagnostics) do io.stderr:write(tostring(note),'\n') end
print(string.format('Quaver: %d modules, %d reachable source bytes → %d module bytes (%d bundle bytes)',
  #result.report.retained,result.report.reachable_input_bytes,result.report.output_bytes,#bytes))

end
local ok,err=pcall(run)
if not ok then
 if type(err)~='table' or not err.code then err=require('quaver.diagnostic').new('QV900',tostring(err),nil,1,arg[2],'The CLI could not finish the requested operation.','Check paths and configuration.') end
 err.stage=err.stage or (last_result and 'cli_emit' or 'cli_configuration')
 if last_result and not err.partial_report then
  local compiled=last_result.host or last_result
  err.partial_report={status='failed',stages=compiled.report.stages};err.trace=compiled.trace
  if last_result.regions then
   err.completed_scopes={host=last_result.host.report,regions={}}
   for name,region in pairs(last_result.regions)do err.completed_scopes.regions[name]=region.report end
  end
 end
 io.stderr:write(tostring(err),'\n')
 if failure_path~=false then
  local saved,save_error=pcall(write_path,failure_path,require('quaver.report').failure(err))
  if saved then io.stderr:write('Partial report: ',failure_path,'\n')else io.stderr:write('Could not save partial report: ',tostring(save_error),'\n')end
 end
 os.exit(1)
end
