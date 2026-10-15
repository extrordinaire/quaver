return {mode="strict",format="bundle",minify=true,
  entry='app',roots={'examples','../valua/src'},
  facades={['valua.init']={exports={'object','pipe','string','min_length','optional','number','safe_parse'}}},
}
