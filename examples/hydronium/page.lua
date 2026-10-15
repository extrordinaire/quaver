local element = require('hydronium.core.element')
local server = require('hydronium_dom.server')
local h = element.h
return function(title)
  local function Card(props)
    return h('article', {class='card',style={paddingTop=12,opacity=.8}}, h('h2', {}, props.title), props.children)
  end
  return server.render_to_string(h('main', {id='app'},
    h('h1', {}, title),
    h(Card, {title='A smaller site'}, h('p', {}, 'Lua < HTML & "escaping"')),
    h('a', {href='/docs?q=a&b=c'}, 'Read the guide'),
    h('input', {disabled=true, value='safe < value'})))
end
