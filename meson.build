project('missive', ['c', 'vala'],
          version: '1.2.0',
    meson_version: '>= 1.0.0',
  default_options: [
    'warning_level=2',
  ],
)

app_id = 'fr.benjaminbellamy.missive'
gettext_package = 'missive'
resource_base = '/fr/benjaminbellamy/missive'

gnome = import('gnome')
i18n = import('i18n')

add_project_arguments(
  '-DGETTEXT_PACKAGE="@0@"'.format(gettext_package),
  language: 'c',
)

# GMime is bundled into the app prefix; its generated vapi lives there too.
add_project_arguments(
  ['--vapidir', get_option('prefix') / 'share' / 'vala' / 'vapi'],
  language: 'vala',
)

prefix = get_option('prefix')
localedir = prefix / get_option('localedir')

conf = configuration_data()
conf.set('APP_ID', app_id)
conf.set('VERSION', meson.project_version())
conf.set('GETTEXT_PACKAGE', gettext_package)
conf.set('LOCALEDIR', localedir)
conf.set('RESOURCE_BASE', resource_base)

subdir('data')
subdir('src')
subdir('po')

gnome.post_install(
  glib_compile_schemas: true,
  gtk_update_icon_cache: true,
  update_desktop_database: true,
)
