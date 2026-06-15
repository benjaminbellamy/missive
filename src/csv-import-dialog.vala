// SPDX-License-Identifier: GPL-3.0-or-later

namespace Missive {
    // After a CSV file is parsed, this dialog names the sheet, picks the default
    // recipient column, and stores the sheet plus its rows in the database.
    [GtkTemplate (ui = "/fr/bellamy/missive/csv-import-dialog.ui")]
    public class CsvImportDialog : Adw.Dialog {
        [GtkChild] private unowned Adw.EntryRow name_row;
        [GtkChild] private unowned Adw.ComboRow recipient_row;
        [GtkChild] private unowned Gtk.Label summary_label;
        [GtkChild] private unowned Gtk.Button cancel_button;
        [GtkChild] private unowned Gtk.Button import_button;

        public signal void imported ();

        private Database db;
        private CsvData data;
        private string source_filename;

        public CsvImportDialog (Database db, CsvData data, string suggested_name,
                                string source_filename) {
            Object ();
            this.db = db;
            this.data = data;
            this.source_filename = source_filename;

            name_row.text = suggested_name;
            recipient_row.model = new Gtk.StringList (data.columns);
            recipient_row.selected = guess_recipient_column ();
            summary_label.label = _("%d columns, %d rows").printf (
                data.columns.length, data.rows.length);

            cancel_button.clicked.connect (() => close ());
            import_button.clicked.connect (on_import);
        }

        // Prefer a column whose name looks like an email address holder.
        private uint guess_recipient_column () {
            for (uint i = 0; i < data.columns.length; i++) {
                var c = data.columns[i].down ();
                if (c.contains ("mail") || c.contains ("courriel")) {
                    return i;
                }
            }
            return 0;
        }

        private void on_import () {
            var name = name_row.text.strip ();
            if (name == "") {
                name_row.add_css_class ("error");
                name_row.grab_focus ();
                return;
            }
            name_row.remove_css_class ("error");

            string recipient_column = data.columns.length > 0
                ? data.columns[recipient_row.selected] : "";

            var sheet = new CsvSheet () {
                name = name,
                source_filename = source_filename,
                columns_json = JsonUtil.array_to_string (data.columns),
                row_count = data.rows.length,
                default_recipient_column = recipient_column,
                imported_at = new DateTime.now_utc ().to_unix ()
            };

            try {
                db.insert_sheet (sheet);
                CsvRow[] rows = {};
                for (int r = 0; r < data.rows.length; r++) {
                    rows += new CsvRow () {
                        idx = r,
                        data_json = JsonUtil.object_to_string (data.columns, data.rows[r].fields)
                    };
                }
                db.insert_rows (sheet.id, rows);
            } catch (DatabaseError e) {
                warning ("Could not import sheet: %s", e.message);
                return;
            }

            imported ();
            close ();
        }
    }
}
