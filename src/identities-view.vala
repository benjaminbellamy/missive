// SPDX-License-Identifier: GPL-3.0-or-later

namespace Missive {
    // The Identities section: an empty state or a boxed list of identities,
    // each with Duplicate and Delete actions; activating a row edits it.
    [GtkTemplate (ui = "/fr/bellamy/missive/identities-view.ui")]
    public class IdentitiesView : Adw.Bin {
        [GtkChild] private unowned Gtk.Stack view_stack;
        [GtkChild] private unowned Gtk.ListBox identity_list;

        private Database db;

        public IdentitiesView (Database db) {
            Object ();
            this.db = db;
            refresh ();
        }

        public void refresh () {
            Ui.clear_list (identity_list);

            Identity[] items = {};
            try {
                items = db.all_identities ();
            } catch (DatabaseError e) {
                warning ("Could not load identities: %s", e.message);
            }

            if (items.length == 0) {
                view_stack.visible_child_name = "empty";
                return;
            }

            view_stack.visible_child_name = "list";
            foreach (var it in items) {
                identity_list.append (make_row (it));
            }
        }

        private Gtk.Widget make_row (Identity it) {
            var row = new Adw.ActionRow () {
                title = it.name != "" ? it.name : _("(unlabeled)"),
                subtitle = it.from_email,
                activatable = true
            };

            var duplicate = new Gtk.Button.from_icon_name ("edit-copy-symbolic") {
                valign = Gtk.Align.CENTER,
                tooltip_text = _("Duplicate")
            };
            duplicate.add_css_class ("flat");
            duplicate.clicked.connect (() => duplicate_identity (it));

            var delete = new Gtk.Button.from_icon_name ("user-trash-symbolic") {
                valign = Gtk.Align.CENTER,
                tooltip_text = _("Delete")
            };
            delete.add_css_class ("flat");
            delete.clicked.connect (() => confirm_delete (it));

            row.add_suffix (duplicate);
            row.add_suffix (delete);
            row.activated.connect (() => edit (it));
            return row;
        }

        public void new_identity () {
            open_editor (null);
        }

        private void edit (Identity it) {
            open_editor (it);
        }

        private void open_editor (Identity? it) {
            var editor = new IdentityEditor (db, it);
            editor.saved.connect (refresh);
            editor.present (get_root () as Gtk.Widget);
        }

        private void duplicate_identity (Identity it) {
            var copy = new Identity () {
                name = _("%s (copy)").printf (it.name),
                from_name = it.from_name,
                from_email = it.from_email,
                smtp_host = it.smtp_host,
                smtp_port = it.smtp_port,
                smtp_encryption = it.smtp_encryption,
                smtp_username = it.smtp_username,
                signature_html = it.signature_html
            };
            try {
                db.insert_identity (copy);
            } catch (DatabaseError e) {
                warning ("Could not duplicate identity: %s", e.message);
                return;
            }
            // Carry the credential over to the new identity, if any.
            var pw = SecretStore.lookup_password (it.id);
            if (pw != null) {
                SecretStore.store_password (copy.id, pw);
            }
            refresh ();
        }

        private void confirm_delete (Identity it) {
            Ui.confirm_delete (this, _("Delete Identity?"),
                _("“%s” will be permanently removed.").printf (
                    it.name != "" ? it.name : _("(unlabeled)")),
                () => {
                    try {
                        db.delete_identity (it.id);
                    } catch (DatabaseError e) {
                        warning ("Could not delete identity: %s", e.message);
                        return;
                    }
                    SecretStore.clear_password (it.id);
                    refresh ();
                });
        }
    }
}
