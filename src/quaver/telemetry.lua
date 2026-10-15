-- Deterministic pass records and a separate, non-reproducible CPU-time trace.
local diagnostic=require('quaver.diagnostic')
local M={}
local function pack(...)return {n=select('#',...),...}end
local function unpack_values(values)return (table.unpack or unpack)(values,1,values.n)end
function M.new()
 local session={report={schema_version=1,status='running',stages={}},trace={schema_version=1,clock='process_cpu_seconds',events={}}}
 function session:run(record,fn)
  record.status='running';self.report.stages[#self.report.stages+1]=record
  local event={stage=record.stage,module=record.module,status='running'}
  self.trace.events[#self.trace.events+1]=event
  local started=os.clock()
  local values=pack(pcall(fn,record))
  event.elapsed_seconds=math.max(0,os.clock()-started)
  if not values[1]then
   local err=values[2]
   if type(err)~='table' or not err.code then
    err=diagnostic.new(record.stage=='validation' and 'QV001' or 'QV900',tostring(err),nil,1,record.module and record.module..'.lua' or '<build>',
     'The compiler could not complete this stage.','Check the input and configuration; report unexpected failures with the compiler version and a minimal reproduction.')
   end
   err.stage=err.stage or record.stage;err.module=err.module or record.module
   record.status='failed';record.error={code=err.code,message=err.message,stage=err.stage,module=err.module}
   event.status='failed';event.code=err.code
   self.report.status='failed';err.partial_report=err.partial_report or self.report;err.trace=err.trace or self.trace
   error(err,0)
  end
  record.status='success';event.status='success'
  local output={n=values.n-1};for index=2,values.n do output[index-1]=values[index]end
  return unpack_values(output)
 end
 function session:skip(record,reason)
  record.status='skipped';record.reason=reason;self.report.stages[#self.report.stages+1]=record
 end
 return session
end
return M
