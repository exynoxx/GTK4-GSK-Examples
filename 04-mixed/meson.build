project('gsk-mixed', 'vala', 'c',
  version: '0.1.0',
  meson_version: '>= 0.59',
)

gtk_dep = dependency('gtk4')

cc = meson.get_compiler('c')
m_dep = cc.find_library('m', required: true)

executable('gsk-mixed',
  'main.vala',
  dependencies: [gtk_dep, m_dep],
  install: false,
)
