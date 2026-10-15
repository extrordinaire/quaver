package.path='src/?.lua;src/?/init.lua;'..package.path
local q=require('quaver')
local function build(options) options.mode='strict';options.minify=true;return q.build(options) end
local lexer=require('quaver.lexer')
local literal=require('quaver.literal')
local total=0
local function test(name,fn) fn();total=total+1;print('PASS '..name) end
local function read(path) local f=assert(io.open(path,'rb'));local s=f:read('*a');f:close();return s end
local function chunk(source)
  local f,err=(loadstring or load)(source,'@quaver-test');assert(f,err);return f
end
local function fails(fn,expected)
  local ok,err=pcall(fn);assert(not ok,'expected rejection');assert(tostring(err):find(expected,1,true),tostring(err))
end
local function inventory(root)
  local modules={}
  local handle=assert(io.popen('find '..root..' -type f -name "*.lua"'))
  for path in handle:lines() do
    local id=path:sub(#root+2):gsub('%.lua$',''):gsub('/','.')
    modules[id]=read(path)
  end
  assert(handle:close());return modules
end
local valua=inventory('../valua/src')
local own=inventory('src')
local original_path=package.path
package.path='../valua/src/?.lua;../valua/src/?/init.lua;'..package.path
local original_validate=chunk(read('examples/app.lua'))()
package.path=original_path
local exports={'object','pipe','string','min_length','optional','number','safe_parse'}
local profile={['valua.init']={pure=true,exports=exports}}
valua.app=read('examples/app.lua')
local result=build({entry='app',modules=valua,facades=profile})
test('Valua selection removes unused primitives and tooling',function()
  assert(not result.modules['valua.schemas.union'])
  assert(not result.modules['valua.contracts'])
  assert(result.modules['valua.schemas.object'])
  assert(result.report.output_bytes<result.report.reachable_input_bytes)
  assert(#result.report.removed>30)
end)
test('optimized Valua preserves outputs, issue paths, Standard Schema and aliases',function()
  -- Lua objects come from different factories; compare the structured values.
  local function equal(a,b)
    if type(a)~=type(b) then return false end
    if type(a)~='table' then return a==b end
    for k,v in pairs(a) do if not equal(v,b[k]) then return false end end
    for k in pairs(b) do if a[k]==nil then return false end end
    return true
  end
  for _,level in ipairs({'safe','compact','mangle'})do
    local built=q.build({mode='strict',entry='app',modules=valua,facades=profile,minify={level=level}})
    local validate=chunk(q.bundle(built))()
    for _,input in ipairs({{name='Lua',age=30},{name='a'},{name=false,age='old'},{name='Moonstone'},{}}) do
      assert(equal(original_validate(input),validate(input)),'validation result drifted at '..level)
    end
  end
  local aliased=build({entry='valua.init',modules=valua,
    facades={['valua.init']={pure=true,exports={'nil','meta','safe_parse','string'}}}})
  local v=chunk(q.bundle(aliased))();assert(v['nil']==v.nil_);assert(v.meta==v.annotate)
  assert(v.string()['~standard'].validate('works').value=='works')
end)
test('minifier preserves token spelling and executed results',function()
  local cases={
    'local x = 1 -- comment\nreturn x',
    'local a=2; return a - -1',
    'return 1 .. "x", .5, 0xff, 1e-3',
    'return "--not a comment", [=[long -- string\ntext]=]',
    'local s="escaped\\\"quote";return s',
    'local x=1; --[==[ comment ]==]\nreturn x',
    '-- comment\rreturn 1',
    '#!/usr/bin/env lua\rreturn 1',
    'return "a\\\nb"',
  }
  for _,source in ipairs(cases) do
    local output=q.minify(source)
    local a,b=lexer.scan(source),lexer.scan(output);assert(#a==#b)
    for i=1,#a do assert(a[i].text==b[i].text) end
    local executable=source:gsub('^#![^\r\n]*','')
    local expected={chunk(executable)()};local actual={chunk(output)()}
    for i=1,#expected do assert(expected[i]==actual[i]) end
  end
end)
test('all Valua and Quaver sources still compile after minification',function()
  for _,modules in ipairs({valua,own}) do for id,source in pairs(modules) do
    local ok,err=pcall(chunk,q.minify(source));assert(ok,id..': '..tostring(err))
  end end
end)
test('literal module names decode without executing source',function()
  for _,text in ipairs({'"valua\\046schemas"','[=[\nvalua.schemas]=]','"valua\\x2eschemas"'}) do
    assert(literal.value(lexer.scan(text)[1])=='valua.schemas')
  end
  assert(literal.value(lexer.scan('"a\\z \n b"')[1])=='ab')
end)
test('dynamic dependencies and unsafe facade profiles fail explicitly',function()
  fails(function() build({entry='app',modules={app='return require(name)'}}) end,'dynamic/aliased')
  fails(function() build({entry='app',modules={app='local r=require;return r("x")'}}) end,'dynamic/aliased')
  fails(function() build({entry='app',modules={app='return require("missing")'}}) end,'Unresolved')
  assert(build({entry='valua.init',modules=valua,facades={['valua.init']={exports=exports}}}).modules['valua.init'])
  fails(function() build({entry='app',modules={app='local v={} print("effect") return v'},facades={app={pure=true,exports={}}}}) end,'QV105')
end)
test('dependency closure retains effects, handles external policy and is deterministic',function()
  local modules={app='local x=require("effect");return x',effect='return "effect"',unused='error("must not execute")'}
  local a=build({entry='app',modules=modules});local b=build({entry='app',modules=modules})
  assert(q.bundle(a)==q.bundle(b));assert(chunk(q.bundle(a))()=='effect')
  local external=build({entry='app',modules={app='return require("math")'},externals={math=true}})
  assert(chunk(q.bundle(external))()==math)
end)
test('Quaver minifier is independently shakeable through its public facade',function()
  own.app='local q=require("quaver");return function(...) return q.minifier.minify(...) end'
  local slim=build({entry='app',modules=own,facades={quaver={pure=true,exports={'minifier'}}}})
  assert(slim.modules['quaver.minifier']);assert(slim.modules['quaver.lexer'])
  assert(not slim.modules['quaver.optimizer']);assert(not slim.modules['quaver.tree_shaker'])
  assert(not slim.modules['quaver.ballad']);assert(not slim.modules.main)
  local minify=chunk(q.bundle(slim))();assert(minify('return 1 -- comment')=='return 1')
end)
test('tree-shaker and optimizer are independently consumable and self-hosting',function()
  for _,name in ipairs({'tree_shaker','optimizer','build','regions'}) do
    own.app='return require("quaver.'..name..'")'
    local built=q.build({mode='strict',entry='app',modules=own,minify={level='mangle'}})
    assert(not built.modules['quaver.ballad']);assert(not built.modules.main)
    if name=='tree_shaker' then assert(not built.modules['quaver.minifier']);assert(not built.modules['quaver.optimizer']) end
    local api=chunk(q.bundle(built))()
    if name=='optimizer' then
      assert(not built.modules['quaver.minifier']);assert(not built.modules['quaver.tree_shaker'])
      assert(api.optimize('return 42')=='return 42')
    elseif name=='regions' then
      local result=api.build({host={entry='x',modules={x='return 42'}},regions={core={entry='x',modules={x='return 42'}}}})
      assert(result.regions.core.modules.x and result.host.modules.x)
    else
      local run=api.shake or api.build
      assert(run({entry='x',modules={x='return 42'}}).modules.x)
    end
  end
end)
test('module registry is isolated from host package.loaded',function()
  local built=build({entry='app',modules={app='return require("valua")',valua='return "private"'}})
  assert(chunk(q.bundle(built))()=='private')
end)
test('bundle loader preserves false-return reloads, failed retries and global names',function()
  -- Test the emitter separately from Strict's source acceptance policy.
  local modules={
    app='local s=require("state");require("falsemod");require("falsemod");pcall(function()require("broken")end);pcall(function()require("broken")end);return {count=s.count,errors=s.errors,global=loaded}',
    state='return {count=0,errors=0}',
    falsemod='local s=require("state");s.count=s.count+1;return false',
    broken='local s=require("state");s.errors=s.errors+1;error("failed")',
  }
  local previous=_G.loaded;_G.loaded='host global'
  local observed=chunk(q.bundle({entry='app',modules=modules,report={mode='strict',retained={'app','broken','falsemod','state'}}}))()
  _G.loaded=previous
  assert(observed.count==2 and observed.errors==2 and observed.global=='host global')
end)
print(string.format('%d tests passed; Valua: %d retained / %d removed modules, %d → %d module bytes (%d bundle bytes)',
  total,#result.report.retained,#result.report.removed,result.report.input_bytes,result.report.output_bytes,#q.bundle(result)))

dofile("tests/flavors.lua")

dofile('tests/contracts.lua')

dofile('tests/regions.lua')

dofile('tests/minification.lua')

dofile('tests/mangle.lua')

dofile('tests/telemetry.lua')
