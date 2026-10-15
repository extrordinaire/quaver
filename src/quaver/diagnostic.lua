local M={}
local mt={}
function mt:__tostring()
 local location=self.path..':'..self.line..':'..self.column
 return (self.stage and 'Stage '..self.stage..(self.module and ' ('..self.module..')' or '')..'\n' or '')..(self.region and 'Region '..self.region..'\n' or '')..'quaver: '..self.code..'\n'..self.message..'\n\n  '..location..'\n\n'..self.explanation
   ..'\n\nSuggestion: '..self.suggestion
end
function M.new(code,message,source,offset,path,explanation,suggestion,severity)
 offset=offset or 1;local prefix=(source or ''):sub(1,offset-1)
 local _,line=prefix:gsub('\n','');local column=#prefix-(prefix:match('.*()\n') or 0)+1
 return setmetatable({code=code,message=message,path=path or '<module>',line=line+1,column=column,
   explanation=explanation or '',suggestion=suggestion or '',severity=severity or 'error'},mt)
end
function M.raise(...) error(M.new(...),0) end
return M
