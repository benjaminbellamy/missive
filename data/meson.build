blueprint_compiler = find_program('blueprint-compiler')

blueprints = custom_target('blueprints',
  input: files(
    'ui/window.blp',
    'ui/identities-view.blp',
    'ui/identity-editor.blp',
    'ui/csv-sheets-view.blp',
    'ui/csv-import-dialog.blp',
    'ui/csv-preview-dialog.blp',
    'ui/templates-view.blp',
    'ui/template-editor.blp',
    'ui/campaigns-view.blp',
    'ui/campaign-dialog.blp',
    'ui/campaign-detail.blp',
    'ui/help-dialog.blp',
  ),
  output: [
    'window.ui',
    'identities-view.ui',
    'identity-editor.ui',
    'csv-sheets-view.ui',
    'csv-import-dialog.ui',
    'csv-preview-dialog.ui',
    'templates-view.ui',
    'template-editor.ui',
    'campaigns-view.ui',
    'campaign-dialog.ui',
    'campaign-detail.ui',
    'help-dialog.ui',
  ],
  command: [
    blueprint_compiler,
    'batch-compile',
    '@OUTDIR@',
    meson.current_source_dir() / 'ui',
    '@INPUT@',
  ],
)

resources = gnome.compile_resources('missive-resources',
  'fr.benjaminbellamy.missive.gresource.xml',
  source_dir: meson.current_build_dir(),
  dependencies: blueprints,
  c_name: 'missive',
)

# Desktop entry
desktop_file = i18n.merge_file(
  input: 'fr.benjaminbellamy.missive.desktop.in',
  output: 'fr.benjaminbellamy.missive.desktop',
  type: 'desktop',
  po_dir: meson.project_source_root() / 'po',
  install: true,
  install_dir: get_option('datadir') / 'applications',
)

desktop_validate = find_program('desktop-file-validate', required: false)
if desktop_validate.found()
  test('Validate desktop file', desktop_validate,
    args: [desktop_file],
  )
endif

# AppStream metainfo
metainfo_file = i18n.merge_file(
  input: 'fr.benjaminbellamy.missive.metainfo.xml.in',
  output: 'fr.benjaminbellamy.missive.metainfo.xml',
  type: 'xml',
  po_dir: meson.project_source_root() / 'po',
  install: true,
  install_dir: get_option('datadir') / 'metainfo',
)

appstreamcli = find_program('appstreamcli', required: false)
if appstreamcli.found()
  test('Validate appstream file', appstreamcli,
    args: ['validate', '--no-net', '--explain', metainfo_file],
  )
endif

# GSettings schema
install_data(
  'fr.benjaminbellamy.missive.gschema.xml',
  install_dir: get_option('datadir') / 'glib-2.0' / 'schemas',
)

# Compile schemas into the build tree so the app can run uninstalled too.
gnome.compile_schemas(depend_files: files('fr.benjaminbellamy.missive.gschema.xml'))

compile_schemas = find_program('glib-compile-schemas', required: false)
if compile_schemas.found()
  test('Validate GSettings schema', compile_schemas,
    args: ['--strict', '--dry-run', meson.current_source_dir()],
  )
endif

# Icons
install_data(
  'icons/hicolor/scalable/apps/fr.benjaminbellamy.missive.svg',
  install_dir: get_option('datadir') / 'icons' / 'hicolor' / 'scalable' / 'apps',
)
install_data(
  'icons/hicolor/symbolic/apps/fr.benjaminbellamy.missive-symbolic.svg',
  install_dir: get_option('datadir') / 'icons' / 'hicolor' / 'symbolic' / 'apps',
)
