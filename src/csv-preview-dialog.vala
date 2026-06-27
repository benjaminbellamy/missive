// SPDX-License-Identifier: GPL-3.0-or-later

namespace Missive {
    // Shows the first rows of a sheet in a table and lets the user change the
    // default recipient column (persisted immediately).
    [GtkTemplate (ui = "/fr/benjaminbellamy/missive/csv-preview-dialog.ui")]
    public class CsvPreviewDialog : Adw.Dialog {
        [GtkChild] private unowned Gtk.DropDown recipient_dropdown;
        [GtkChild] private unowned Gtk.Label row_count_label;
        [GtkChild] private unowned Gtk.Grid table_grid;

        private const int PREVIEW_LIMIT = 100;

        private Database db;
        private CsvSheet sheet;
        private string[] columns;

        public CsvPreviewDialog (Database db, CsvSheet sheet) {
            Object ();
            this.db = db;
            this.sheet = sheet;
            title = sheet.name;

            columns = JsonUtil.string_to_array (sheet.columns_json);
            recipient_dropdown.model = new Gtk.StringList (columns);
            recipient_dropdown.selected = recipient_index ();
            recipient_dropdown.notify["selected"].connect (on_recipient_changed);

            build_table ();
        }

        private uint recipient_index () {
            for (uint i = 0; i < columns.length; i++) {
                if (columns[i] == sheet.default_recipient_column) {
                    return i;
                }
            }
            return 0;
        }

        private void on_recipient_changed () {
            if (recipient_dropdown.selected >= columns.length) {
                return;
            }
            sheet.default_recipient_column = columns[recipient_dropdown.selected];
            try {
                db.update_sheet (sheet);
            } catch (DatabaseError e) {
                warning ("Could not update recipient column: %s", e.message);
            }
        }

        private void build_table () {
            CsvRow[] rows = {};
            try {
                rows = db.rows_for_sheet (sheet.id);
            } catch (DatabaseError e) {
                warning ("Could not load rows: %s", e.message);
            }

            for (int c = 0; c < columns.length; c++) {
                table_grid.attach (header_cell (columns[c]), c, 0, 1, 1);
            }

            int shown = int.min (rows.length, PREVIEW_LIMIT);
            for (int r = 0; r < shown; r++) {
                var map = JsonUtil.string_to_object (rows[r].data_json);
                for (int c = 0; c < columns.length; c++) {
                    var value = map.lookup (columns[c]) ?? "";
                    table_grid.attach (value_cell (value), c, r + 1, 1, 1);
                }
            }

            if (rows.length > shown) {
                row_count_label.label = _("Showing first %d of %d rows").printf (
                    shown, rows.length);
            } else {
                row_count_label.label = _("%d rows").printf (rows.length);
            }
        }

        private Gtk.Widget header_cell (string text) {
            var label = new Gtk.Label (text) {
                halign = Gtk.Align.START,
                xalign = 0,
                margin_top = 6,
                margin_bottom = 6,
                margin_start = 10,
                margin_end = 10
            };
            label.add_css_class ("heading");
            return label;
        }

        private Gtk.Widget value_cell (string text) {
            return new Gtk.Label (text) {
                halign = Gtk.Align.START,
                xalign = 0,
                ellipsize = Pango.EllipsizeMode.END,
                max_width_chars = 32,
                margin_top = 4,
                margin_bottom = 4,
                margin_start = 10,
                margin_end = 10
            };
        }
    }
}
