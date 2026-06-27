// SPDX-License-Identifier: GPL-3.0-or-later

namespace Missive {
    // The CSV Sheets section: an empty state or a boxed list of sheets. The
    // header Import action drives the file chooser; activating a row previews it.
    [GtkTemplate (ui = "/fr/benjaminbellamy/missive/csv-sheets-view.ui")]
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

            // UTF-16/UTF-32 files (e.g. some spreadsheet exports) contain NUL
            // bytes that would truncate the byte string; decode them first.
            string? decoded = decode_unicode (contents);
            if (decoded != null) {
                parse_and_import (file, decoded);
                return;
            }

            // Plain UTF-8 (checked on the raw bytes, so a stray NUL can't pass).
            if (((string) contents).validate (contents.length)) {
                parse_and_import (file, (string) contents);
                return;
            }

            // Otherwise ask which single-byte encoding it was saved in.
            ask_encoding (file, contents);
        }

        private void parse_and_import (File file, string text) {
            try {
                open_import (file, CsvParser.parse (text));
            } catch (CsvError e) {
                toast (csv_error_message (e));
            }
        }

        // Decode a UTF-16/UTF-32 file to UTF-8, or return null when the bytes
        // are not Unicode-with-NULs. Endianness comes from a BOM when present,
        // otherwise from which half of each byte pair tends to be zero.
        private static string? decode_unicode (uint8[] c) {
            string? from = null;
            if (c.length >= 4 && c[0] == 0xFF && c[1] == 0xFE
                && c[2] == 0x00 && c[3] == 0x00) {
                from = "UTF-32LE";
            } else if (c.length >= 4 && c[0] == 0x00 && c[1] == 0x00
                && c[2] == 0xFE && c[3] == 0xFF) {
                from = "UTF-32BE";
            } else if (c.length >= 2 && c[0] == 0xFF && c[1] == 0xFE) {
                from = "UTF-16LE";
            } else if (c.length >= 2 && c[0] == 0xFE && c[1] == 0xFF) {
                from = "UTF-16BE";
            } else {
                // BOM-less UTF-16: only when NULs are frequent enough to be the
                // padding bytes of two-byte code units, not stray bytes.
                int even = 0, odd = 0;
                int sample = int.min (c.length, 4096);
                for (int i = 0; i < sample; i++) {
                    if (c[i] == 0x00) {
                        if (i % 2 == 0) {
                            even++;
                        } else {
                            odd++;
                        }
                    }
                }
                if (even + odd <= sample / 4) {
                    return null;
                }
                from = odd >= even ? "UTF-16LE" : "UTF-16BE";
            }
            try {
                return GLib.convert ((string) c, c.length, "UTF-8", from);
            } catch (ConvertError e) {
                return null;
            }
        }

        // Offer a list of common single-byte encodings, decode the raw bytes
        // with the chosen one, and parse the result. Takes ownership of the
        // bytes so they stay alive until the (deferred) dialog response fires.
        private void ask_encoding (File file, owned uint8[] contents) {
            string[] labels = {
                _("Western European (ISO-8859-1)"),
                _("Western European (ISO-8859-15)"),
                _("Western European (Windows-1252)"),
                _("Central European (ISO-8859-2)"),
                _("Cyrillic (Windows-1251)"),
                _("Greek (ISO-8859-7)"),
                _("Turkish (ISO-8859-9)")
            };
            string[] charsets = {
                "ISO-8859-1", "ISO-8859-15", "WINDOWS-1252",
                "ISO-8859-2", "WINDOWS-1251", "ISO-8859-7", "ISO-8859-9"
            };

            var dropdown = new Gtk.DropDown (new Gtk.StringList (labels), null) {
                hexpand = true
            };

            var dialog = new Adw.AlertDialog (_("Select File Encoding"),
                _("This file is not valid UTF-8. Choose the encoding it was saved in."));
            dialog.set_extra_child (dropdown);
            dialog.add_response ("cancel", _("Cancel"));
            dialog.add_response ("open", _("Import"));
            dialog.set_response_appearance ("open", Adw.ResponseAppearance.SUGGESTED);
            dialog.default_response = "open";
            dialog.close_response = "cancel";
            dialog.response.connect ((response) => {
                if (response != "open") {
                    return;
                }
                var charset = charsets[dropdown.selected];
                string utf8;
                try {
                    utf8 = GLib.convert ((string) contents, contents.length,
                                         "UTF-8", charset);
                } catch (ConvertError ce) {
                    toast (_("Could not decode the file as %s.").printf (charset));
                    return;
                }
                parse_and_import (file, utf8);
            });
            dialog.present (get_root () as Gtk.Widget);
        }

        private void open_import (File file, CsvData data) {
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
