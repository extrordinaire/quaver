local lexer = require('quaver.lexer')
local literal=require('quaver.literal')
local M = {}
-- Narrow, explicit grammar: local v={}; v.key=require('module')[.field];
-- v.alias=v.key; return v. No executable statement is silently discarded.
function M.select(source, requested)
  local ts, pos, records, order = lexer.scan(source), 1, {}, {}
  local function peek() return ts[pos] and ts[pos].text end
  local function take(text)
    local t=ts[pos]; if not t or (text and t.text~=text) then error('unsupported facade syntax near '..tostring(peek()),0) end
    pos=pos+1; return t
  end
  local function name()
    local t=take(); if t.kind~='name' then error('expected facade name',0) end; return t.text
  end
  local function key()
    if peek()=='.' then take('.'); return name() end
    take('[');local k=literal.value(take());take(']');return k
  end
  take('local'); local binding=name();take('=');take('{');take('}')
  while peek()~='return' do
    if peek()==';' then take(';') end
    if peek()=='return' then break end
    local start=pos;take(binding);local field=key();take('=')
    if records[field] then error('duplicate facade export '..field,0) end
    local record={field=field}
    if peek()=='require' then
      take('require');take('(');literal.value(take());take(')')
      if peek()=='.' then take('.');name() end
    elseif peek()==binding then take(binding);record.alias=key()
    else error('facade export '..field..' is not a static require or alias',0) end
    record.source=source:sub(ts[start].start,ts[pos-1].finish)
    records[field]=record;order[#order+1]=record
  end
  take('return');take(binding);if peek()==';' then take(';') end
  if peek() then error('unsupported statements after facade return',0) end
  local kept={}
  local function keep(field)
    if kept[field] then return end
    local r=records[field];if not r then error('unknown facade export '..tostring(field),0) end
    kept[field]=true;if r.alias then keep(r.alias) end
  end
  for _,field in ipairs(requested) do keep(field) end
  local out={'local '..binding..'={}'}
  local removed={}
  for _,r in ipairs(order) do
    if kept[r.field] then out[#out+1]=r.source else removed[#removed+1]=r.field end
  end
  out[#out+1]='return '..binding
  return table.concat(out,'\n'), removed
end
return M
