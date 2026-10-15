local lexer=require('quaver.lexer')
local diagnostic=require('quaver.diagnostic')
local telemetry=require('quaver.telemetry')
local M={}
--- Private module registry. Generate names absent from all input modules so
--- an ordinary global such as `loaded` never captures our implementation.
function M.bundle(result)
  local session=telemetry.new()
  for _,record in ipairs(result.report.stages or {})do if record.stage~='bundle' then session.report.stages[#session.report.stages+1]=record end end
  for _,event in ipairs(result.trace and result.trace.events or {})do session.trace.events[#session.trace.events+1]=event end
  return session:run({stage='bundle'},function(record)
  if result.report.mode~='strict' or result.report.preserved then diagnostic.raise('QV110','This program requires ordinary module-file emission.',nil,1,result.entry..'.lua','A private bundle loader is not equivalent to arbitrary Lua runtime loading.','Emit module files; reserve bundle output for an explicit strict artifact.') end
  local used={}
  for _,source in pairs(result.modules) do for _,t in ipairs(lexer.scan(source)) do
    if t.kind=='name' then used[t.text]=true end
  end end
  local index=0
  local factories,loaded,loading,host
  repeat
    local prefix='__quaver'..index..'_';index=index+1
    factories,loaded,loading,host=prefix..'factories',prefix..'loaded',prefix..'loading',prefix..'host'
  until not(used[factories] or used[loaded] or used[loading] or used[host])
  local out={ 'local '..factories..','..loaded..','..loading..'={},{},{}',
    'local '..host..'=require','local function require(name)',
    'if '..loaded..'[name] then return '..loaded..'[name] end',
    'local factory='..factories..'[name];if not factory then return '..host..'(name) end',
    'if '..loading..'[name] then error("Quaver: circular require: "..name) end',
    loading..'[name]=true;local ok,value=pcall(factory,name);'..loading..'[name]=nil',
    'if not ok then error(value,0) end',
    'if value==nil then value=true end;'..loaded..'[name]=value;return value end' }
  for _,id in ipairs(result.report.retained) do
    out[#out+1]=factories..'['..string.format('%q',id)..']=function(...)\n'..result.modules[id]..'\nend'
  end
  out[#out+1]='return require('..string.format('%q',result.entry)..')'
  local source=table.concat(out,'\n')..'\n'
  record.input_bytes=0;for _,bytes in pairs(result.modules)do record.input_bytes=record.input_bytes+#bytes end
  record.output_bytes=#source;record.counters={modules=#result.report.retained}
  session.report.status='success';result.report.stages=session.report.stages;result.trace=session.trace
  return source
  end)
end
return M
