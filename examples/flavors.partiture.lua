-- Workspace demonstration before Moonstone's flavor branch is released.
-- A flavor-capable `moon sync` supplies this canonical module automatically.
package.path='src/?.lua;src/?/init.lua;../moonstone/src/core/assets/lua/?.lua;'..package.path
local ballad=require('ballad')
return ballad.partiture(function(p)
  local quaver=p:use(require('quaver.ballad'))
  local files=p.source.files({'*.lua'},{root='examples/flavors'})
  p.sink.directory(quaver.optimize(files,{entry='app',mode='strict',format='bundle',minify=true,flavor='lua51-x86_64-linux',name='flavor.lua'}),{
    out='dist/flavors',incremental=true,
  })
end)
