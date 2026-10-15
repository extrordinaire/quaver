local target=require('moonstone.target')
local compat=require('compat')
return function()
  if target.level>=53 then
    return 'modern:'..compat
  else
    return 'classic:'..compat
  end
end
