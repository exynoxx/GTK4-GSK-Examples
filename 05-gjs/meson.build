project('gsk-demo-gjs',
  version: '0.1.0',
  meson_version: '>= 0.59',
)

# GJS is an interpreter — no compilation step.
# This run target lets you do:  meson compile -C builddir run
run_target('run',
  command: ['gjs', '-m', files('main.js')],
)
