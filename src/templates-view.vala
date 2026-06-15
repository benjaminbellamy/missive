// SPDX-License-Identifier: GPL-3.0-or-later

namespace Missive {
    // The Templates section: an empty state or a boxed list of templates, each
    // with Duplicate and Delete; activating a row opens the editor.
    [GtkTemplate (ui = "/fr/bellamy/missive/templates-view.ui")]
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

        private void edit (Template template) {
            open_editor (template);
        }

        private void open_editor (Template? template) {
            var editor = new TemplateEditor (db, template);
            editor.saved.connect (refresh);
            editor.present (get_root () as Gtk.Widget);
        }

        private void duplicate_template (Template template) {
            var now = new DateTime.now_utc ().to_unix ();
            var copy = new Template () {
                name = _("%s (copy)").printf (template.name),
                subject = template.subject,
                body_html = template.body_html,
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
