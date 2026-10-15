-- This proof example needs Valua's local-helper fix until it is in a release;
-- CI pins moonstone-sh/valua commit 253601b7e8841458d62efe4bcdd1f7441a56887b.
package.path='src/?.lua;src/?/init.lua;'..package.path
local ballad=require('ballad')
return ballad.partiture(function(p)
  local quaver=p:use(require('quaver.ballad'))
  local sources=p.source.files({'**/*.lua'},{root='../valua/src'})
  local consumer=p.source.files({'app.lua'},{root='examples'})
  local optimized=quaver.optimize(sources,{
    entry='app',mode='strict',format='bundle',minify={level="safe"},depends_on={consumer},name='validate.lua',
    facades={['valua.init']={exports={'object','pipe','string','min_length','optional','number','safe_parse'}}},
  })
  p.sink.directory(optimized,{out='dist/valua',incremental=true})
end)
