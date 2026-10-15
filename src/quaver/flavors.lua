-- Moonstone integration boundary. Selection is delegated to Moonstone's
-- canonical variants module; core optimization passes do not import it.
local M={}
local function optional(name) local ok,value=pcall(require,name);if ok then return value end end
local function contains(values,wanted) for _,v in ipairs(values) do if v==wanted then return true end end end
function M.context(options)
  options=options or {}
  local host=options.host_target
  if host==nil then host=optional('moonstone.target') end
  local environment
  if options.getenv then environment=options.getenv('MOONSTONE_TARGET') else environment=os.getenv('MOONSTONE_TARGET') end
  local id=environment or options.flavor or (host and host.id)
  if id==nil then return nil end
  local variants=options.variants or require('moonstone.variants')
  local language,arch,os_name=id:match('^([^-]+)%-([^-]+)%-([^-]+)$')
  assert(language and contains(variants.language_tags,language) and contains(variants.arch_tags,arch)
    and contains(variants.os_tags,os_name),'invalid MOONSTONE_TARGET: '..tostring(id))
  local same=host and host.id==id
  local target
  if same then target=host else
    target={id=id,arch=arch,os=os_name,family=language:match('^lua%d%d$') and 'lua' or language,
      level=tonumber(language:match('^lua(%d%d)$')) or 51}
  end
  return {target=target,runtime_known=not not same,project=options.project or optional('moonstone.project'),variants=variants}
end
function M.select(files,context)
  local variants,groups=context.variants,{}
  local paths={};for path in pairs(files) do paths[#paths+1]=path end;table.sort(paths)
  for _,path in ipairs(paths) do
    assert(path:match('%.lua$'),'expected a .lua source file: '..path)
    local directory,filename=path:match('^(.-)([^/]*)$')
    local variant,err=variants.parse(filename)
    assert(variant~=false,err)
    local base=variant and directory..variant.stem..variant.ext or path
    local group=groups[base] or {candidates={},paths={}};groups[base]=group
    if variant then group.candidates[#group.candidates+1]=variant;group.paths[#group.paths+1]=path
    else assert(not group.base,'duplicate base '..base);group.base=path end
  end
  local out,selected={},{}
  local bases={};for base in pairs(groups) do bases[#bases+1]=base end;table.sort(bases)
  for _,base in ipairs(bases) do
    local g=groups[base]
    local choice,index,other=variants.select(g.candidates,g.base~=nil,context.target)
    assert(choice~='ambiguous','ambiguous variants for '..base..' ('..context.target.id..'): '
      ..tostring(g.paths[index])..' / '..tostring(g.paths[other]))
    local path=choice=='variant' and g.paths[index] or choice=='base' and g.base or nil
    if path then
      local id=base:gsub('%.lua$',''):gsub('/','.')
      assert(not out[id],'duplicate module '..id);out[id]=files[path];selected[id]=path
    end
  end
  return out,selected
end
return M
