// SPDX-License-Identifier: GPL-3.0-or-later

namespace Missive {
    // The CSV Sheets section: an empty state or a boxed list of sheets. The
    // header Import action drives the file chooser; activating a row previews it.
    [GtkTemplate (ui = "/fr/bellamy/missive/csv-sheets-view.ui")]
    public class CsvSheetsView : Adw.Bin {
        [GtkChild] private unowned Gtk.Stack view_stack;
        [GtkChild] private unowned Gtk.ListBox sheet_list;

        private Database db;

        public CsvSheetsView (Database db) {
            Object ();
            this.db = db;
            refresh ();
        }

        public void refresh () {
            Ui.clear_list (sheet_list);

            CsvSheet[] items = {};
            try {
                items = db.all_sheets ();
            } catch (DatabaseError e) {
                warning ("Could not load sheets: %s", e.message);
            }

            if (items.length == 0) {
                view_stack.visible_child_name = "empty";
                return;
            }

            view_stack.visible_child_name = "list";
            foreach (var sheet in items) {
                sheet_list.append (make_row (sheet));
            }
        }

        private Gtk.Widget make_row (CsvSheet sheet) {
            int columns = JsonUtil.string_to_array (sheet.columns_json).length;
            var row = new Adw.ActionRow () {
                title = sheet.name,
                subtitle = _("%d columns · %d rows").printf (columns, sheet.row_count),
                activatable = true
            };

            var delete = new Gtk.Button.from_icon_name ("user-trash-symbolic") {
                valign = Gtk.Align.CENTER,
                tooltip_text = _("Delete")
            };
            delete.add_css_class ("flat");
            delete.clicked.connect (() => confirm_delete (sheet));

            row.add_suffix (delete);
            row.activated.connect (() => preview (sheet));
            return row;
        }

        private void preview (CsvSheet sheet) {
            var dialog = new CsvPreviewDialog (db, sheet);
            dialog.present (get_root () as Gtk.Widget);
        }

        // Open the portal-backed file chooser, then parse off the main loop.
        public void import_sheet () {
            var dialog = new Gtk.FileDialog () {
                title = _("Import CSV File")
            };
            var filter = new Gtk.FileFilter () {
                name = _("CSV Files")
            };
            filter.add_mime_type ("text/csv");
            filter.add_suffix ("csv");
            var filters = new GLib.ListStore (typeof (Gtk.FileFilter));
            filters.append (filter);
            dialog.filters = filters;

            dialog.open.begin (get_root () as Gtk.Window, null, (obj, res) => {
                File file;
                try {
                    file = dialog.open.end (res);
                } catch (Error e) {
                    return; // dismissed
                }
                load_file.begin (file);
            });
        }

        private async void load_file (File file) {
            uint8[] contents;
            try {
                yield file.load_contents_async (null, out contents, null);
            } catch (Error e) {
                toast (_("Could not read the file."));
                return;
            }

            CsvData data;
            try {
                data = CsvParser.parse ((string) contents);
            } catch (CsvError e) {
                toast (csv_error_message (e));
                return;
            }

            var dialog = new CsvImportDialog (db, data, derive_name (file),
                                              file.get_basename () ?? "");
            dialog.imported.connect (refresh);
            dialog.present (get_root () as Gtk.Widget);
        }

        private string derive_name (File file) {
            var stem = file.get_basename () ?? _("Imported sheet");
            if (stem.down ().has_suffix (".csv")) {
                stem = stem.substring (0, stem.length - 4);
            }
            return stem;
        }

        private string csv_error_message (CsvError e) {
            switch (e.code) {
                case CsvError.NOT_UTF8:
                    return _("The file is not valid UTF-8.");
                case CsvError.NO_HEADER:
                    return _("The file is empty or has no header row.");
                case CsvError.NO_DATA:
                    return _("The file has a header but no data rows.");
                default:
                    return _("The file could not be read as CSV.");
            }
        }

        private void confirm_delete (CsvSheet sheet) {
            Ui.confirm_delete (this, _("Delete CSV Sheet?"),
                _("“%s” will be permanently removed.").printf (sheet.name),
                () => {
                    try {
                        db.delete_sheet (sheet.id);
                    } catch (DatabaseError e) {
                        warning ("Could not delete sheet: %s", e.message);
                        return;
                    }
                    refresh ();
                });
        }

        private void toast (string text) {
            Ui.toast (this, text);
        }
    }
}
