-- Run from Quaver: moon exec -- lua examples/hydronium/verify.lua /path/to/hydronium
-- This experiment preserves the complete inventory; observed load counts are
-- measurements, never used as evidence to delete modules.
package.path='src/?.lua;src/?/init.lua;'..package.path
local q=require('quaver')
local root=assert(arg[1],'Supply a Hydronium checkout')
local function quote(value)return "'"..value:gsub("'","'\\''").."'"end
local function read(path)local f=assert(io.open(path,'rb'));local s=f:read('*a');f:close();return s end
local function write(path,value)
 assert(os.execute('mkdir -p '..quote(path:match('^(.*)/'))))
 local f=assert(io.open(path,'wb'));f:write(value);f:close()
end
local inventory={}
for _,member in ipairs({'core','dom','router'})do
 local directory=root..'/'..member..'/src'
 local files=assert(io.popen('find '..quote(directory)..' -type f -name "*.lua"'))
 for path in files:lines()do
  local id=path:sub(#directory+2):gsub('%.lua$',''):gsub('/','.')
  assert(not inventory[id],'Duplicate module '..id);inventory[id]=read(path)
 end
 assert(files:close())
end
local page=read('examples/hydronium/page.lua')
local variants={narrow=page,broad=page:gsub("require%('hydronium.core.element'%)","require('hydronium')")}
local temp=os.tmpname();os.remove(temp);assert(os.execute('mkdir -p '..quote(temp)))
local worker=[=[
local directory,variant=arg[1],arg[2]
package.path=directory..'/?.lua;'..directory..'/?/init.lua;'..package.path
local render=require('probe')
local html=render('Hello <Hydronium>')
assert(html:find('Hello &lt;Hydronium&gt;',1,true))
assert(html:find('Lua &lt; HTML &amp; &quot;escaping&quot;',1,true))
assert(html:find('q=a&amp;b=c',1,true))
assert(html==render('Hello <Hydronium>'),'Render state leaked between calls')
local json=require('hydronium_dom.server.json')
local style=require('hydronium_dom.style')
local checks={html}
for _,value in ipairs({'escaped " text','Unicode: λ','line\nbreak',''})do
 local encoded=json.encode({message=value});assert(json.decode(encoded).message==value)
 checks[#checks+1]=encoded
end
assert(not pcall(json.decode,'{"bad":}'))
checks[#checks+1]=style.serialize({paddingTop=12,opacity=.8,['--accent']='violet'})
local output=assert(io.open(directory..'/render.html','wb'));output:write(table.concat(checks,'\n'));output:close()
local loaded=assert(io.open(directory..'/loaded.txt','w'))
for id in pairs(package.loaded)do if id:match('^hydronium')then loaded:write(id,'\n')end end
loaded:close()
]=]
write(temp..'/worker.lua',worker)
local executable=assert(arg[-1] or arg[0])
local records={}
for _,variant in ipairs({'broad','narrow'})do
 inventory.probe=variants[variant]
 local conservative=q.build({entry='probe',modules=inventory,mode='conservative',minify={level='mangle'}})
 assert(conservative.report.preserved and conservative.report.minification.applied=='none')
 for id,source in pairs(inventory)do assert(conservative.modules[id]==source)end
 local ok,strict=pcall(q.build,{entry='probe',modules=inventory,mode='strict',minify={level='mangle'}})
 if ok then print(variant..' strict: available')else assert(type(strict)=='table' and strict.code);print(variant..' strict: '..tostring(strict))end
 local baseline
 for _,level in ipairs({'none','compact','compact-helpers'})do
  local directory=temp..'/'..variant..'-'..level
  local bytes={}
  for id,source in pairs(inventory)do
   local output=q.minify(source,{level=level=='none' and 'none' or 'compact'})
   if level=='compact-helpers' and (id=='hydronium_dom.style' or id=='hydronium_dom.server.json')then
    local helper=q.build({entry=id,modules={[id]=source},mode='strict',minify={level='mangle'}})
    output=helper.modules[id]
   end
   bytes[id]=#output
   write(directory..'/'..id:gsub('%.','/')..'.lua',output)
  end
  local command=quote(executable)..' '..quote(temp..'/worker.lua')..' '..quote(directory)..' '..quote(variant)
  local success=os.execute(command);assert(success==true or success==0,'SSR worker failed')
  local html=read(directory..'/render.html')
  if baseline then assert(html==baseline,'Compaction changed SSR HTML')else baseline=html end
  local count,total,seen=0,bytes.probe,{}
  for id in read(directory..'/loaded.txt'):gmatch('[^\n]+')do
   local canonical=bytes[id]and id or id..'.init'
   assert(bytes[canonical],'Loaded module outside supplied inventory: '..id)
   if not seen[canonical]then count=count+1;total=total+bytes[canonical];seen[canonical]=true end
  end
  print(string.format('%s %s: %d loaded modules + page, %d Lua bytes, %d verified output bytes',variant,level,count,total,#html))
  records[variant..'-'..level]={bytes=total,html=html}
 end
end
assert(records['broad-none'].html==records['narrow-none'].html,'Narrow imports changed HTML')
print('PASS: complete-inventory preservation; escaped and repeated SSR; broad/narrow/compact HTML and helper equivalence')
assert(os.execute('rm -rf '..quote(temp)))
