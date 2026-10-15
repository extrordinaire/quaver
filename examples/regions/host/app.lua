local validate=require('__quaver_regions.validator')
return function(plugin_name,input)
  local plugin=require(plugin_name)
  return validate(plugin(input))
end
