-- Semantic optimization is independent of graph closure and minification.
local specialize=require('quaver.specialize').specialize
local M={}
---@param source string
---@param context? table Target grammar and optional immutable Moonstone metadata.
---@param options? table
---@return string
---@return table
function M.optimize(source,context,options)
  assert(type(source)=='string','optimizer expects Lua source text')
  if not context then return source,{folded_fields=0,removed_branches=0} end
  return specialize(source,context,options)
end
return M
