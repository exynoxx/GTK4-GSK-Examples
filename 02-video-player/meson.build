project('gsk-video-player', 'vala', 'c',
  version: '0.1.0',
  meson_version: '>= 0.59',
)

gtk_dep = dependency('gtk4')

cc = meson.get_compiler('c')
m_dep = cc.find_library('m', required: false)

executable('gsk-video-player',
  'controls_bar.vala',
  'empty_state.vala',
  'video_player_canvas.vala',
  'main.vala',
  dependencies: [gtk_dep, m_dep],
  install: false,
)
