-- Stable, data-only Lua reports. A proof record is evidence from this verifier,
-- not a security attestation. Callers provide the content hash implementation.
local M={}
local function encode(value)
 local kind=type(value)
 if kind=='string' then return string.format('%q',value) end
 if kind=='boolean' or kind=='number' then return tostring(value) end
 assert(kind=='table','report values must be plain data')
 local keys={};for key in pairs(value) do keys[#keys+1]=key end
 table.sort(keys,function(a,b)if type(a)==type(b) then return a<b end;return type(a)<type(b) end)
 local out={'{'}
 for _,key in ipairs(keys) do out[#out+1]='['..encode(key)..']='..encode(value[key])..',' end
 out[#out+1]='}';return table.concat(out)
end
M.encode=encode
function M.render(result,options,inputs,hash)
 options=options or {};local digests,outputs={},{}
 if hash then
  for id,source in pairs(inputs or {}) do digests[id]=hash(source) end
  for id,source in pairs(result.modules) do outputs[id]=hash(source) end
 end
 local profiles={}
 for id,profile in pairs(options.facades or {}) do
  local exports={};for _,name in ipairs(profile.exports or {}) do exports[#exports+1]=name end;table.sort(exports);profiles[id]=exports
 end
 return 'return '..encode({schema_version=1,compiler_version=require('quaver.version'),mode=result.report.mode,
  entry=result.entry,source_hashes=digests,output_hashes=outputs,hash_algorithm=hash and 'blake3' or 'not_recorded',
  minification=result.report.minification or {requested='none',applied='none'},before_minify_bytes=result.report.before_minify_bytes or result.report.output_bytes,
  input_bytes=result.report.input_bytes,analyzed_closure_bytes=result.report.analyzed_closure_bytes,analyzed_closure_modules=result.report.analyzed_closure_modules,output_bytes=result.report.output_bytes,
  bundle_stats=result.report.bundle_stats or {},
  stages=result.report.stages or {},decisions=result.report.decisions or {},module_stats=result.report.module_stats or {},
  profiles=profiles,boundaries=options.boundaries or {},proofs=result.report.proofs,
  retained=result.report.retained,removed=result.report.removed,preserved=result.report.preserved or false,
  target=result.report.target or 'unspecified'})..'\n'
end
function M.failure(err)
 return 'return '..encode({schema_version=1,status='failed',created_at_utc=os.date('!%Y-%m-%dT%H:%M:%SZ'),diagnostic={code=err.code,message=err.message,
  stage=err.stage,module=err.module,region=err.region,path=err.path,line=err.line,column=err.column,suggestion=err.suggestion},
  partial_report=err.partial_report or {},trace=err.trace or {},completed_scopes=err.completed_scopes or {}})..'\n'
end
return M
