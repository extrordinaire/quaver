-- Decode literal module names without invoking Lua's loader/evaluator.
local M={}
local escapes={a='\a',b='\b',f='\f',n='\n',r='\r',t='\t',v='\v',['\\']='\\',['"']='"',["'"]="'"}
local function utf8(code)
  assert(code<=0x10ffff and not(code>=0xd800 and code<=0xdfff),'invalid Unicode escape')
  if code<128 then return string.char(code) end
  if code<2048 then return string.char(192+math.floor(code/64),128+code%64) end
  if code<65536 then return string.char(224+math.floor(code/4096),128+math.floor(code/64)%64,128+code%64) end
  return string.char(240+math.floor(code/262144),128+math.floor(code/4096)%64,128+math.floor(code/64)%64,128+code%64)
end
function M.value(token)
  assert(token and token.kind=='string','expected a literal string')
  local text=token.text
  local eq=text:match('^%[(=*)%[')
  if eq then
    local body=text:sub(#eq+3,-#eq-3):gsub('\r\n','\n'):gsub('\n\r','\n'):gsub('\r','\n')
    return (body:gsub('^\n',''))
  end
  local out,pos={},2
  while pos<#text do
    local c=text:sub(pos,pos);pos=pos+1
    if c=='\\' then
      c=text:sub(pos,pos);pos=pos+1
      if escapes[c] then c=escapes[c]
      elseif c=='z' then while text:sub(pos,pos):match('%s') do pos=pos+1 end;c=''
      elseif c=='x' then
        local hex=text:sub(pos,pos+1);assert(hex:match('^%x%x$'),'invalid hex escape');c=string.char(tonumber(hex,16));pos=pos+2
      elseif c=='u' then
        local hex=text:sub(pos):match('^%{(%x+)%}');assert(hex,'invalid Unicode escape');c=utf8(tonumber(hex,16));pos=pos+#hex+2
      elseif c:match('%d') then
        local digits=c..(text:sub(pos):match('^%d%d?') or '');local n=tonumber(digits);assert(n<=255,'invalid decimal escape');c=string.char(n);pos=pos+#digits-1
      elseif c=='\n' or c=='\r' then
        if (c=='\r' and text:sub(pos,pos)=='\n') or (c=='\n' and text:sub(pos,pos)=='\r') then pos=pos+1 end;c='\n'
      else error('unsupported string escape '..c,0) end
    end
    out[#out+1]=c
  end
  return table.concat(out)
end
return M
