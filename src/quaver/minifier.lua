local lexer = require('quaver.lexer')
local diagnostic=require('quaver.diagnostic')
---@alias quaver.MinificationLevel 'none'|'safe'|'compact'|'mangle'
---@alias quaver.Minification boolean|{level:quaver.MinificationLevel}
---@param value? quaver.Minification
---@param default? quaver.MinificationLevel
---@return quaver.MinificationLevel
local function level(value,default)
  if value==nil then return default or 'none' end
  if value==true then return 'safe' end
  if value==false then return 'none' end
  if type(value)=='table' then
    local valid=true
    for key in pairs(value)do if key~='level' then valid=false end end
    if valid and (value.level=='none' or value.level=='safe' or value.level=='compact' or value.level=='mangle') then return value.level end
  end
  diagnostic.raise('QV001','Invalid minification level.',nil,1,'<minifier>',
    'Supported levels are none, safe, compact, and mangle.',
    'Use minify={level="safe"}, {level="compact"}, {level="none"}, {level="mangle"}, or a boolean.')
end
---@param source string Valid Lua source; original token spelling is preserved.
---@param options? quaver.Minification|{preserve_lines:boolean}
---@param target? table Lua grammar target, used only for mangling.
---@return string
---@return table statistics
local function minify(source,options,target)
  -- Preserve the standalone API's historical compact default and legacy
  -- preserve_lines option. Build configuration uses named levels exclusively.
  if type(options)=='table' and options.preserve_lines~=nil then
    local valid=type(options.preserve_lines)=='boolean' and options.level==nil
    for key in pairs(options)do if key~='preserve_lines' then valid=false end end
    if not valid then diagnostic.raise('QV001','Conflicting minifier options.',nil,1,'<minifier>','Legacy preserve_lines cannot be combined with named levels.','Use only {level="safe"} or {level="compact"}.') end
    options={level=options.preserve_lines and 'safe' or 'compact'}
  end
  if type(options)=='table' and next(options)==nil then options=nil end
  local selected=level(options,'compact')
  if selected=='none' then return source,{level=selected,input_bytes=#source,output_bytes=#source,renamed_bindings=0} end
  local original_bytes,renamed=#source,0
  if selected=='mangle' then local stats;source,stats=require('quaver.mangle').mangle(source,target);renamed=stats.renamed end
  local preserve_lines=selected=='safe'
  local tokens, out, previous = lexer.scan(source), {}, nil
  local cursor=1
  local function lines(text)
    text=text:gsub('\r\n','\n'):gsub('\n\r','\n'):gsub('\r','\n')
    local _,count=text:gsub('\n','');return count
  end
  for _, token in ipairs(tokens) do
    local newline=preserve_lines and lines(source:sub(cursor,token.start-1)) or 0
    if newline>0 then out[#out+1]=string.rep('\n',newline) end
    if previous and newline==0 then
      -- Retokenize the boundary: only remove separation if both spellings
      -- remain exactly the same two tokens. This catches --, .., and numbers.
      local ok, pair = pcall(lexer.scan, previous.text .. token.text)
      local words=(previous.kind=='name' or previous.kind=='number') and (token.kind=='name' or token.kind=='number')
      if words or not ok or #pair~=2 or pair[1].text~=previous.text or pair[2].text~=token.text then
        out[#out+1]=' '
      end
    end
    out[#out+1]=token.text; previous=token;cursor=token.finish+1
  end
  if preserve_lines then out[#out+1]=string.rep('\n',lines(source:sub(cursor))) end
  local output=table.concat(out)
  return output,{level=selected,input_bytes=original_bytes,output_bytes=#output,renamed_bindings=renamed}
end

return {minify=minify,level=level}
