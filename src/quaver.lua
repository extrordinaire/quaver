local q={}
q.tree_shaker=require('quaver.tree_shaker')
q.minifier=require('quaver.minifier')
q.optimizer=require('quaver.optimizer')
q.minify=require('quaver.minifier').minify
q.build=require('quaver.build').build
q.bundle=require('quaver.bundle').bundle
q.regions=require('quaver.regions')
q.version=require('quaver.version')
return q
