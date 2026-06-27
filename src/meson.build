config_vala = configure_file(
  input: 'config.vala.in',
  output: 'config.vala',
  configuration: conf,
)

missive_sources = files(
  'main.vala',
  'application.vala',
  'window.vala',
  'database.vala',
  'secret-store.vala',
  'identity.vala',
  'template.vala',
  'csv-sheet.vala',
  'campaign.vala',
  'identities-view.vala',
  'identity-editor.vala',
  'json-util.vala',
  'lang.vala',
  'csv-parser.vala',
  'csv-sheets-view.vala',
  'csv-import-dialog.vala',
  'csv-preview-dialog.vala',
  'html-serializer.vala',
  'html-import.vala',
  'templates-view.vala',
  'template-editor.vala',
  'substitution.vala',
  'message-builder.vala',
  'smtp-sender.vala',
  'email-util.vala',
  'ui-util.vala',
  'campaigns-view.vala',
  'campaign-dialog.vala',
  'campaign-detail.vala',
  'campaign-engine.vala',
  'help-dialog.vala',
  'missive-smtp.vapi',
)

# The libcurl SMTP shim is built as a C-only static library so libcurl (which
# has no Vala binding) is never passed to valac; the .vapi binds the shim.
smtp_shim = static_library('missive-smtp',
  'missive-smtp.c',
  dependencies: [
    dependency('glib-2.0'),
    dependency('libcurl'),
  ],
)

missive_deps = [
  dependency('glib-2.0'),
  dependency('gobject-2.0'),
  dependency('gio-2.0'),
  dependency('gtk4'),
  dependency('libadwaita-1', version: '>= 1.4'),
  dependency('sqlite3'),
  dependency('libsecret-1'),
  dependency('json-glib-1.0'),
  dependency('webkitgtk-6.0'),
  dependency('gmime-3.0'),
  dependency('libxml-2.0'),
  dependency('gtksourceview-5'),
]

executable('missive',
  missive_sources,
  config_vala,
  resources,
  dependencies: missive_deps,
  include_directories: include_directories('.'),
  link_with: smtp_shim,
  install: true,
)
