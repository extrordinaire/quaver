package.path='src/?.lua;src/?/init.lua;'..package.path
local ballad=require('ballad')
return ballad.partiture(function(p)
  local quaver=p:use(require('quaver.ballad'))
  local host=p.source.files({'*.lua'},{root='examples/regions/host'})
  local valua=p.source.files({'**/*.lua'},{root='../valua/src'})
  local validator=p.source.files({'app.lua'},{root='examples'})
  local output=quaver.compose(host,{
    depends_on={valua,validator},
    host={entry='app',inputs={1},boundaries={app={kind='runtime',reason='Plugins are selected at runtime'}}},
    regions={validator={entry='app',inputs={2,3},minify={level="safe"},
      facades={['valua.init']={exports={'object','pipe','string','min_length','optional','number','safe_parse'}}}}},
  })
  p.sink.directory(output,{out='dist/regions',incremental=true})
end)
