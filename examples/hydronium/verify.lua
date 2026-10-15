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
local variants={narrow=page,broad=page:gsub("require%('hydronium.core.element'%)","require('hydronium')"),renderer=page:gsub("require%('hydronium_dom.server'%)","require('hydronium_dom.server.renderer')")}
local temp=os.tmpname();os.remove(temp);assert(os.execute('mkdir -p '..quote(temp)))
local worker=[=[
local directory,variant=arg[1],arg[2]
package.path=directory..'/?.lua;'..directory..'/?/init.lua;'..package.path
local api
if arg[3]=='bundle' then api=assert(loadfile(directory..'/bundle.lua'))()
elseif arg[3]=='files' then api=require('fixture_entry') end
local render=api and api.render or require('probe')
local html=render('Hello <Hydronium>')
assert(html:find('Hello &lt;Hydronium&gt;',1,true))
assert(html:find('Lua &lt; HTML &amp; &quot;escaping&quot;',1,true))
assert(html:find('q=a&amp;b=c',1,true))
assert(html==render('Hello <Hydronium>'),'Render state leaked between calls')
local json=api and {encode=api.encode,decode=api.decode} or require('hydronium_dom.server.json')
local style=api and {serialize=api.serialize} or require('hydronium_dom.style')
local element=api and {h=api.h} or require('hydronium.core.element')
local server=api and {render_to_string=api.render_to_string} or require(variant=='renderer' and 'hydronium_dom.server.renderer' or 'hydronium_dom.server')
local checks={html}
checks[#checks+1]=server.render_to_string(element.h('svg',{},element.h('linearGradient',{strokeWidth=2}),element.h('feGaussianBlur',{})))
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
local variantNames={'broad','narrow'}
if inventory['hydronium_dom.server.renderer'] then variantNames[#variantNames+1]='renderer' end
for _,variant in ipairs(variantNames)do
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
 if variant=='renderer' and ok then
  local modules={};for id,source in pairs(inventory)do modules[id]=source end
  modules.fixture_entry=[[local render=require('probe')
local element=require('hydronium.core.element')
local server=require('hydronium_dom.server.renderer')
local json=require('hydronium_dom.server.json')
local style=require('hydronium_dom.style')
return {render=render,h=element.h,render_to_string=server.render_to_string,encode=json.encode,decode=json.decode,serialize=style.serialize}]]
  local artifact=q.build({entry='fixture_entry',modules=modules,mode='strict',minify={level='mangle'}})
  -- Probe real consumer profiles without weakening initializer or export proofs.
  -- Each attempt is independent: a rejected profile never changes the artifact.
  for _,candidate in ipairs({
   {id='hydronium_dom.server.renderer',exports={'render_to_string'}},
   {id='hydronium.core.element',exports={'h'}},
   {id='hydronium_dom.style',exports={'serialize','UNITLESS_NUMBER_PROPS','camel_to_kebab'}},
  })do
   local accepted,profiled=pcall(q.build,{entry='fixture_entry',modules=modules,mode='strict',
    facades={[candidate.id]={exports=candidate.exports}},minify={level='mangle'}})
   if accepted then
    -- Selection support may improve independently. Execute any accepted result
    -- against the same baseline before describing its size as a usable win.
    local directory=temp..'/profile-'..candidate.id
    local source=q.bundle(profiled);write(directory..'/bundle.lua',source)
    local success=os.execute(quote(executable)..' '..quote(temp..'/worker.lua')..' '..quote(directory)..' renderer bundle')
    assert(success==true or success==0,'Profile worker failed: '..candidate.id)
    assert(read(directory..'/render.html')==baseline,'Profile changed output: '..candidate.id)
    print(string.format('renderer profile %s: %d verified bundle bytes',candidate.id,#source))
   else
    assert(type(profiled)=='table' and profiled.code,'Unstructured profile failure')
    print('renderer profile '..candidate.id..': '..tostring(profiled))
   end
  end
  for _,format in ipairs({'files','bundle'})do
   local directory=temp..'/strict-'..format
   local total,count=0,0
   for _ in pairs(artifact.modules)do count=count+1 end
   if format=='files' then
    for id,source in pairs(artifact.modules)do
     write(directory..'/'..id:gsub('%.','/')..'.lua',source)
     total=total+#source
    end
   else
    local source=q.bundle(artifact);write(directory..'/bundle.lua',source);total=#source
   end
   local success=os.execute(quote(executable)..' '..quote(temp..'/worker.lua')..' '..quote(directory)..' renderer '..format)
   assert(success==true or success==0,'Strict '..format..' worker failed')
   assert(read(directory..'/render.html')==baseline,'Strict '..format..' changed output')
   print(string.format('renderer strict-%s: %d retained modules, %d artifact bytes (includes verification entry)',format,count,total))
  end
 end
end
assert(records['broad-none'].html==records['narrow-none'].html,'Narrow imports changed HTML')
if records['renderer-none']then assert(records['renderer-none'].html==records['narrow-none'].html,'Plain renderer changed HTML')end
print('PASS: complete-inventory preservation; escaped and repeated SSR; broad/narrow/compact HTML and helper equivalence')
assert(os.execute('rm -rf '..quote(temp)))
