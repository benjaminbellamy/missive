// SPDX-License-Identifier: GPL-3.0-or-later

namespace Missive {
    // Modal editor for a single identity. Loads the password from the keyring
    // on open and writes it back on save; the password never goes to SQLite.
    [GtkTemplate (ui = "/fr/bellamy/missive/identity-editor.ui")]
    public class IdentityEditor : Adw.Dialog {
        [GtkChild] private unowned Adw.EntryRow name_row;
        [GtkChild] private unowned Adw.EntryRow from_name_row;
        [GtkChild] private unowned Adw.EntryRow from_email_row;
        [GtkChild] private unowned Adw.EntryRow host_row;
        [GtkChild] private unowned Adw.SpinRow port_row;
        [GtkChild] private unowned Adw.ComboRow encryption_row;
        [GtkChild] private unowned Adw.EntryRow username_row;
        [GtkChild] private unowned Adw.PasswordEntryRow password_row;
        [GtkChild] private unowned Gtk.TextView signature_view;
        [GtkChild] private unowned Gtk.Button cancel_button;
        [GtkChild] private unowned Gtk.Button save_button;
        [GtkChild] private unowned Gtk.Button verify_button;
        [GtkChild] private unowned Adw.ActionRow status_row;
        [GtkChild] private unowned Gtk.Spinner status_spinner;
        [GtkChild] private unowned Gtk.Image status_icon;

        // Guards stale async test results and post-close UI updates.
        private uint test_generation = 0;
        private uint test_timeout = 0;
        private bool is_closed = false;

        // Emitted after a successful save so the list can refresh.
        public signal void saved ();

        private Database db;
        private Identity identity;
        private bool is_new;

        // Index order of the encryption combo, mapped to stored values.
        private const string[] ENCRYPTIONS = {
            ENCRYPTION_SMTPS, ENCRYPTION_STARTTLS, ENCRYPTION_NONE
        };

        public IdentityEditor (Database db, Identity? existing) {
            Object ();
            this.db = db;
            this.is_new = existing == null;
            this.identity = existing ?? new Identity ();

            encryption_row.model = new Gtk.StringList ({
                _("SMTPS (implicit TLS)"),
                _("STARTTLS"),
                _("None (plaintext)")
            });

            title = is_new ? _("New Identity") : _("Edit Identity");

            cancel_button.clicked.connect (() => close ());
            save_button.clicked.connect (on_save);
            verify_button.clicked.connect (run_test);

            load ();

            // Re-test whenever the SMTP parameters change (debounced).
            host_row.changed.connect (schedule_test);
            username_row.changed.connect (schedule_test);
            password_row.changed.connect (schedule_test);
            port_row.notify["value"].connect (schedule_test);
            encryption_row.notify["selected"].connect (schedule_test);

            this.closed.connect (() => {
                is_closed = true;
                test_generation++;
                if (test_timeout != 0) {
                    Source.remove (test_timeout);
                    test_timeout = 0;
                }
            });

            // Test once on open ("seeing" the parameters).
            run_test ();
        }

        private void load () {
            name_row.text = identity.name;
            from_name_row.text = identity.from_name;
            from_email_row.text = identity.from_email;
            host_row.text = identity.smtp_host;
            port_row.value = identity.smtp_port;
            encryption_row.selected = encryption_index (identity.smtp_encryption);
            username_row.text = identity.smtp_username;
            signature_view.buffer.text = identity.signature_html;

            if (!is_new) {
                var pw = SecretStore.lookup_password (identity.id);
                if (pw != null) {
                    password_row.text = pw;
                }
            }
        }

        private uint encryption_index (string value) {
            for (uint i = 0; i < ENCRYPTIONS.length; i++) {
                if (ENCRYPTIONS[i] == value) {
                    return i;
                }
            }
            return 0;
        }

        private void on_save () {
            identity.name = name_row.text.strip ();
            identity.from_name = from_name_row.text.strip ();
            identity.from_email = from_email_row.text.strip ();
            identity.smtp_host = host_row.text.strip ();
            identity.smtp_port = (int) port_row.value;
            identity.smtp_encryption = ENCRYPTIONS[encryption_row.selected];
            identity.smtp_username = username_row.text.strip ();
            identity.signature_html = signature_view.buffer.text;

            // Minimal validation: a name is required to identify the row.
            if (identity.name == "") {
                name_row.add_css_class ("error");
                name_row.grab_focus ();
                return;
            }
            name_row.remove_css_class ("error");

            try {
                if (is_new) {
                    db.insert_identity (identity);
                } else {
                    db.update_identity (identity);
                }
            } catch (DatabaseError e) {
                warning ("Could not save identity: %s", e.message);
                return;
            }

            // Store the password only when one was entered, so clearing the
            // field on edit does not silently wipe a working credential.
            var pw = password_row.text;
            if (pw != "") {
                SecretStore.store_password (identity.id, pw);
            }

            saved ();
            close ();
        }

        // --- connection test --------------------------------------------------

        private void schedule_test () {
            if (test_timeout != 0) {
                Source.remove (test_timeout);
            }
            test_timeout = Timeout.add (900, () => {
                test_timeout = 0;
                run_test ();
                return Source.REMOVE;
            });
        }

        private void run_test () {
            var host = host_row.text.strip ();
            var user = username_row.text.strip ();
            var pass = password_row.text;
            var encryption = ENCRYPTIONS[encryption_row.selected];
            int port = (int) port_row.value;

            if (host == "" || user == "" || pass == "") {
                set_status_idle (_("Enter host, username and password to test"));
                return;
            }

            uint generation = ++test_generation;
            set_status_testing ();

            new Thread<bool> ("smtp-test", () => {
                string? error = MissiveSmtp.test (host, port, encryption, user, pass);
                Idle.add (() => {
                    if (is_closed || generation != test_generation) {
                        return Source.REMOVE;
                    }
                    if (error == null) {
                        set_status_ok ();
                    } else {
                        set_status_failed (error);
                    }
                    return Source.REMOVE;
                });
                return true;
            });
        }

        // spinning: show the spinner; icon/css null hides the icon; tooltip null
        // clears it. Always clears both status CSS classes first.
        private void set_status (bool spinning, string? icon, string? css,
                                 string subtitle, string? tooltip) {
            if (spinning) {
                status_spinner.start ();
            } else {
                status_spinner.stop ();
            }
            status_spinner.visible = spinning;

            status_icon.remove_css_class ("success");
            status_icon.remove_css_class ("error");
            status_icon.visible = icon != null;
            if (icon != null) {
                status_icon.icon_name = icon;
                if (css != null) {
                    status_icon.add_css_class (css);
                }
            }

            status_row.subtitle = subtitle;
            status_row.tooltip_text = tooltip;
        }

        private void set_status_idle (string message) {
            set_status (false, null, null, message, null);
        }

        private void set_status_testing () {
            set_status (true, null, null, _("Testing…"), null);
        }

        private void set_status_ok () {
            set_status (false, "emblem-ok-symbolic", "success", _("Connection OK"), null);
        }

        private void set_status_failed (string error) {
            set_status (false, "dialog-warning-symbolic", "error",
                        _("Failed: %s").printf (error), error);
        }
    }
}

