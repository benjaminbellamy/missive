// SPDX-License-Identifier: GPL-3.0-or-later

namespace Missive {
    // The Templates section: an empty state or a boxed list of templates, each
    // with Duplicate and Delete; activating a row opens the editor.
    [GtkTemplate (ui = "/fr/benjaminbellamy/missive/templates-view.ui")]
    public class TemplatesView : Adw.Bin {
        [GtkChild] private unowned Gtk.Stack view_stack;
        [GtkChild] private unowned Gtk.ListBox template_list;

        private Database db;

        public TemplatesView (Database db) {
            Object ();
            this.db = db;
            refresh ();
        }

        public void refresh () {
            Ui.clear_list (template_list);

            Template[] items = {};
            try {
                items = db.all_templates ();
            } catch (DatabaseError e) {
                warning ("Could not load templates: %s", e.message);
            }

            if (items.length == 0) {
                view_stack.visible_child_name = "empty";
                return;
            }

            view_stack.visible_child_name = "list";
            foreach (var template in items) {
                template_list.append (make_row (template));
            }
        }

        private Gtk.Widget make_row (Template template) {
            var row = new Adw.ActionRow () {
                title = template.name != "" ? template.name : _("(unlabeled)"),
                subtitle = template.subject,
                activatable = true
            };

            var duplicate = new Gtk.Button.from_icon_name ("edit-copy-symbolic") {
                valign = Gtk.Align.CENTER,
                tooltip_text = _("Duplicate")
            };
            duplicate.add_css_class ("flat");
            duplicate.clicked.connect (() => duplicate_template (template));

            var delete = new Gtk.Button.from_icon_name ("user-trash-symbolic") {
                valign = Gtk.Align.CENTER,
                tooltip_text = _("Delete")
            };
            delete.add_css_class ("flat");
            delete.clicked.connect (() => confirm_delete (template));

            row.add_suffix (duplicate);
            row.add_suffix (delete);
            row.activated.connect (() => edit (template));
            return row;
        }

        public void new_template () {
            open_editor (null);
        }

        // Pick a local HTML file, inline its CSS and keep only the <body>
        // content, then open the editor on a new template prefilled with it.
        public void import_html () {
            var dialog = new Gtk.FileDialog () {
                title = _("Import HTML File")
            };
            var filter = new Gtk.FileFilter () {
                name = _("HTML Files")
            };
            filter.add_mime_type ("text/html");
            filter.add_suffix ("html");
            filter.add_suffix ("htm");
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
                load_html.begin (file);
            });
        }

        private async void load_html (File file) {
            uint8[] contents;
            try {
                yield file.load_contents_async (null, out contents, null);
            } catch (Error e) {
                Ui.toast (this, _("Could not read the file."));
                return;
            }

            string text;
            if (((string) contents).validate (contents.length)) {
                text = (string) contents;
            } else {
                // Not UTF-8: assume the common Windows-1252 fallback. libxml2
                // still honours any <meta charset> it finds inside.
                try {
                    text = GLib.convert ((string) contents, contents.length,
                                         "UTF-8", "WINDOWS-1252");
                } catch (ConvertError e) {
                    Ui.toast (this, _("Could not decode the file as text."));
                    return;
                }
            }

            var body = HtmlImport.process (text);
            var editor = new TemplateEditor (db, null, derive_name (file), body);
            editor.saved.connect (refresh);
            editor.transient_for = get_root () as Gtk.Window;
            editor.present ();
        }

        private string derive_name (File file) {
            var stem = file.get_basename () ?? _("Imported template");
            int dot = stem.last_index_of (".");
            if (dot > 0) {
                stem = stem.substring (0, dot);
            }
            return stem;
        }

        private void edit (Template template) {
            open_editor (template);
        }

        private void open_editor (Template? template) {
            var editor = new TemplateEditor (db, template);
            editor.saved.connect (refresh);
            editor.transient_for = get_root () as Gtk.Window;
            editor.present ();
        }

        private void duplicate_template (Template template) {
            var now = new DateTime.now_utc ().to_unix ();
            var copy = new Template () {
                name = _("%s (copy)").printf (template.name),
                subject = template.subject,
                body_html = template.body_html,
                unsubscribe_lang = template.unsubscribe_lang,
                created_at = now,
                updated_at = now
            };
            try {
                db.insert_template (copy);
            } catch (DatabaseError e) {
                warning ("Could not duplicate template: %s", e.message);
                return;
            }
            refresh ();
        }

        private void confirm_delete (Template template) {
            Ui.confirm_delete (this, _("Delete Template?"),
                _("“%s” will be permanently removed.").printf (
                    template.name != "" ? template.name : _("(unlabeled)")),
                () => {
                    try {
                        db.delete_template (template.id);
                    } catch (DatabaseError e) {
                        warning ("Could not delete template: %s", e.message);
                        return;
                    }
                    refresh ();
                });
        }
    }
}
