-- Optional Valua adapter: shape validation cannot establish semantic purity.
-- Inject Valua so no compiler pass acquires a validation-library dependency.
local M={}
function M.create(v)
 local boundary=v.strict_object({kind=v.literal('runtime'),reason=v.pipe(v.string(),v.min_length(1))})
 local profile=v.strict_object({exports=v.array(v.string())})
 local minification=v.union({v.boolean(),v.strict_object({level=v.picklist({'none','safe','compact','mangle'})})})
 local region=v.strict_object({entry=v.pipe(v.string(),v.min_length(1)),
  modules=v.record(v.string(),v.string()),facades=v.optional(v.record(v.string(),profile)),
  minify=v.optional(minification)})
 return {
  region=region,minification=minification,
  contracts=v.strict_object({mode=v.picklist({'conservative','strict'}),minify=v.optional(minification),
    facades=v.optional(v.record(v.string(),profile)),
    boundaries=v.optional(v.record(v.string(),boundary))}),
  boundary=boundary,profile=profile,
 }
end
return M
