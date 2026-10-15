-- Lossless token spelling; trivia is omitted, offsets refer to original bytes.
local M = {}
local compounds = { ['...']=true, ['..']=true, ['//']=true, ['<<']=true, ['>>']=true,
  ['<=']=true, ['>=']=true, ['==']=true, ['~=']=true, ['::']=true }
local function long_end(source, pos)
  local eq = source:sub(pos):match('^%[(=*)%[')
  if not eq then return nil end
  local close = ']' .. eq .. ']'
  local a, b = source:find(close, pos + #eq + 2, true)
  if not a then error('unterminated long string/comment at byte ' .. pos, 0) end
  return b
end
function M.scan(source)
  local out, pos, size = {}, 1, #source
  if source:sub(1,2) == '#!' then pos = (source:find('[\r\n]') or size) + 1 end
  while pos <= size do
    local start, c = pos, source:sub(pos,pos)
    local kind
    if c:match('%s') then pos = pos + 1
    elseif source:sub(pos,pos+1) == '--' then
      local finish = long_end(source, pos+2)
      pos = finish and finish+1 or (source:find('[\r\n]',pos) or size+1)
    elseif c == '"' or c == "'" then
      kind = 'string'; pos = pos+1
      while pos <= size and source:sub(pos,pos) ~= c do
        local ch = source:sub(pos,pos)
        if ch == '\\' then
          pos = pos+1
          if source:sub(pos,pos)=='z' then
            pos=pos+1
            while source:sub(pos,pos):match('%s') do pos=pos+1 end
            pos=pos-1
          end
          local a,b=source:sub(pos,pos),source:sub(pos+1,pos+1)
          if (a=='\r' and b=='\n') or (a=='\n' and b=='\r') then pos=pos+1 end
        elseif ch == '\n' or ch == '\r' then error('unescaped newline in string at byte '..start,0) end
        pos = pos+1
      end
      if pos > size then error('unterminated string at byte '..start,0) end
      pos = pos+1
    elseif c == '[' and source:sub(pos):match('^%[=*%[') then
      kind = 'string'; pos = long_end(source,pos)+1
    elseif c:match('[%a_]') then
      kind='name'; pos=pos+1
      while source:sub(pos,pos):match('[%w_]') do pos=pos+1 end
    elseif c:match('%d') or (c=='.' and source:sub(pos+1,pos+1):match('%d')) then
      kind='number'
      local tail = source:sub(pos)
      local number
      if tail:match('^0[xX]') then
        number = tail:match('^0[xX][%da-fA-F]*%.?[%da-fA-F]*[pP][+-]?%d+')
          or tail:match('^0[xX][%da-fA-F]+%.?[%da-fA-F]*')
          or tail:match('^0[xX][%da-fA-F]*%.?[%da-fA-F]+')
      else
        number = tail:match('^%d*%.?%d+[eE][+-]?%d+')
          or tail:match('^%d+%.%d*[eE][+-]?%d+')
          or tail:match('^%d+%.%d*') or tail:match('^%.%d+') or tail:match('^%d+')
      end
      if not number then error('invalid numeral at byte '..pos,0) end
      pos=pos+#number
      if source:sub(pos,pos):match('[%a_]') then error('invalid or unsupported numeric literal at byte '..start,0) end
    else
      kind='symbol'
      local three, two = source:sub(pos,pos+2), source:sub(pos,pos+1)
      pos=pos+(compounds[three] and 3 or compounds[two] and 2 or 1)
    end
    if kind then out[#out+1]={kind=kind,text=source:sub(start,pos-1),start=start,finish=pos-1} end
  end
  return out
end
return M
