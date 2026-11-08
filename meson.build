project('budgie-classic-alttab-switcher', ['c', 'vala'],
  version: '0.1.0',
  license: 'GPL-2.0-or-later',
  meson_version: '>= 0.60.0',
)

app_id = 'io.github.kubasama.BudgieClassicAltTabSwitcher'
website = 'https://github.com/kubasama/budgie-classic-alttab-switcher'

# Vala's generated C triggers many harmless warnings with newer GCC; keep the
# build quiet and never let them become errors under stricter distro flags.
add_project_arguments(
  '-w',
  '-Wno-error=incompatible-pointer-types',
  language: 'c',
)

deps = [
  dependency('glib-2.0', version: '>= 2.70'),
  dependency('gobject-2.0'),
  dependency('gio-2.0'),
  dependency('gio-unix-2.0'),
  dependency('gtk+-3.0', version: '>= 3.24'),
  dependency('gtk-layer-shell-0', version: '>= 0.6.0'),
  dependency('libxfce4windowing-0', version: '>= 4.20.0'),
  meson.get_compiler('vala').find_library('posix'),
]

prefix = get_option('prefix')
bindir = prefix / get_option('bindir')

conf = configuration_data()
conf.set_quoted('APP_ID', app_id)
conf.set_quoted('VERSION', meson.project_version())
conf.set_quoted('WEBSITE', website)
conf.set_quoted('BINDIR', bindir)
config_vala = configure_file(
  input: 'src/config.vala.in',
  output: 'config.vala',
  configuration: conf,
)

executable(meson.project_name(),
  config_vala,
  'src/main.vala',
  'src/keybindings.vala',
  'src/switcher.vala',
  'src/icons.vala',
  'src/theme.vala',
  dependencies: deps,
  install: true,
)

# Autostart entry: /etc/xdg/autostart, or ~/.config/autostart for a user install
desktop_conf = configuration_data()
desktop_conf.set('BINDIR', bindir)
if get_option('user_install')
  autostart_dir = run_command('sh', '-c', 'echo "${XDG_CONFIG_HOME:-$HOME/.config}/autostart"',
    check: true).stdout().strip()
else
  autostart_dir = get_option('sysconfdir') / 'xdg' / 'autostart'
endif
configure_file(
  input: 'data/budgie-classic-alttab-switcher.desktop.in',
  output: 'budgie-classic-alttab-switcher.desktop',
  configuration: desktop_conf,
  install: true,
  install_dir: autostart_dir,
)
