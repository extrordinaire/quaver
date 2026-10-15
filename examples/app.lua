local v=require('valua')
local schema=v.object({name=v.pipe(v.string(),v.min_length(2)),age=v.optional(v.number())})
return function(input) return v.safe_parse(schema,input) end
