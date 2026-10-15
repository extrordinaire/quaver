package.path='src/?.lua;src/?/init.lua;'..package.path
local ballad=require('ballad')
return ballad.partiture(function(p)
  local quaver=p:use(require('quaver.ballad'))
  local sources=p.source.files({'*.lua'},{root='examples/dynamic'})
  local output=quaver.optimize(sources,{
    mode='strict',entry='app',format='files',
    boundaries={app={kind='runtime',reason='The application selects plugin module names at runtime'}},
  })
  p.sink.directory(output,{out='dist/dynamic',incremental=true})
end)
