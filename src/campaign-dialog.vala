// SPDX-License-Identifier: GPL-3.0-or-later

namespace Missive {
    // Campaign creation flow. Picks an identity, CSV sheet, template, recipient
    // column, CC/BCC and name; on Create it snapshots the template subject/body
    // and materializes one campaign_recipient per CSV row (resolving the To
    // address and skipping empty/invalid ones).
    [GtkTemplate (ui = "/fr/bellamy/missive/campaign-dialog.ui")]
    public class CampaignDialog : Adw.Dialog {
        [GtkChild] private unowned Adw.EntryRow name_row;
        [GtkChild] private unowned Adw.ComboRow identity_row;
        [GtkChild] private unowned Adw.ComboRow sheet_row;
        [GtkChild] private unowned Adw.ComboRow recipient_row;
        [GtkChild] private unowned Adw.ComboRow template_row;
        [GtkChild] private unowned Adw.EntryRow cc_row;
        [GtkChild] private unowned Adw.EntryRow bcc_row;
        [GtkChild] private unowned Gtk.Button cancel_button;
        [GtkChild] private unowned Gtk.Button create_button;

        public signal void created ();

        private Database db;
        private GLib.Settings settings;
        private Identity[] identities;
        private CsvSheet[] sheets;
        private Template[] templates;

        public CampaignDialog (Database db, GLib.Settings settings) {
            Object ();
            this.db = db;
            this.settings = settings;

            try {
                identities = db.all_identities ();
                sheets = db.all_sheets ();
                templates = db.all_templates ();
            } catch (DatabaseError e) {
                warning ("Could not load campaign sources: %s", e.message);
                identities = {};
                sheets = {};
                templates = {};
            }

            identity_row.model = string_list (names_of_identities ());
            sheet_row.model = string_list (names_of_sheets ());
            template_row.model = string_list (names_of_templates ());

            sheet_row.notify["selected"].connect (on_sheet_changed);
            on_sheet_changed ();

            // Pre-fill Cc/Bcc with the global defaults.
            cc_row.text = settings.get_string ("default-cc");
            bcc_row.text = settings.get_string ("default-bcc");

            cancel_button.clicked.connect (() => close ());
            create_button.clicked.connect (on_create);
        }

        private Gtk.StringList string_list (string[] items) {
            return new Gtk.StringList (items.length > 0 ? items
                : new string[] { _("(none)") });
        }

        private string[] names_of_identities () {
            string[] r = {};
            foreach (var it in identities) {
                r += it.name != "" ? it.name : it.from_email;
            }
            return r;
        }

        private string[] names_of_sheets () {
            string[] r = {};
            foreach (var s in sheets) {
                r += s.name;
            }
            return r;
        }

        private string[] names_of_templates () {
            string[] r = {};
            foreach (var t in templates) {
                r += t.name;
            }
            return r;
        }

        // Repopulate the recipient-column combo from the selected sheet.
        private void on_sheet_changed () {
            if (sheets.length == 0) {
                recipient_row.model = new Gtk.StringList (new string[] { _("(none)") });
                return;
            }
            var sheet = sheets[sheet_row.selected];
            var columns = JsonUtil.string_to_array (sheet.columns_json);
            recipient_row.model = new Gtk.StringList (columns);
            for (uint i = 0; i < columns.length; i++) {
                if (columns[i] == sheet.default_recipient_column) {
                    recipient_row.selected = i;
                    break;
                }
            }
        }

        private void on_create () {
            if (identities.length == 0 || sheets.length == 0 || templates.length == 0) {
                toast (_("Create an identity, a CSV sheet and a template first."));
                return;
            }
            var name = name_row.text.strip ();
            if (name == "") {
                name_row.add_css_class ("error");
                name_row.grab_focus ();
                return;
            }
            name_row.remove_css_class ("error");

            var identity = identities[identity_row.selected];
            var sheet = sheets[sheet_row.selected];
            var template = templates[template_row.selected];
            var columns = JsonUtil.string_to_array (sheet.columns_json);
            if (columns.length == 0) {
                toast (_("The selected sheet has no columns."));
                return;
            }
            var recipient_column = columns[recipient_row.selected];
            var now = new DateTime.now_utc ().to_unix ();

            var campaign = new Campaign () {
                name = name,
                status = CAMPAIGN_DRAFT,
                identity_id = identity.id,
                csv_sheet_id = sheet.id,
                recipient_column = recipient_column,
                cc = cc_row.text.strip (),
                bcc = bcc_row.text.strip (),
                subject_snapshot = template.subject,
                body_html_snapshot = template.body_html,
                delay_seconds = settings.get_int ("default-delay-seconds"),
                stop_on_error = settings.get_boolean ("default-stop-on-error"),
                created_at = now
            };

            int skipped = 0;
            try {
                db.insert_campaign (campaign);

                var rows = db.rows_for_sheet (sheet.id);
                CampaignRecipient[] recipients = {};
                for (int i = 0; i < rows.length; i++) {
                    var values = JsonUtil.string_to_object (rows[i].data_json);
                    var to = (values.lookup (recipient_column) ?? "").strip ();
                    var r = new CampaignRecipient () {
                        idx = i,
                        row_data_json = rows[i].data_json
                    };
                    if (to == "") {
                        r.status = RECIPIENT_SKIPPED;
                        r.error_text = _("No address in the recipient column");
                        skipped++;
                    } else if (!EmailUtil.is_valid (to)) {
                        r.to_address = to;
                        r.status = RECIPIENT_SKIPPED;
                        r.error_text = _("Address does not look valid");
                        skipped++;
                    } else {
                        r.to_address = to;
                        r.status = RECIPIENT_PENDING;
                    }
                    recipients += r;
                }
                db.insert_recipients (campaign.id, recipients);

                var unknown = unknown_fields (template, columns);
                if (unknown.length > 0) {
                    toast (_("Campaign created: %d recipients, %d skipped. Unmatched fields: %s").printf (
                        recipients.length - skipped, skipped,
                        string.joinv (", ", unknown)));
                } else {
                    toast (_("Campaign created: %d recipients, %d skipped").printf (
                        recipients.length - skipped, skipped));
                }
            } catch (DatabaseError e) {
                warning ("Could not create campaign: %s", e.message);
                toast (_("Could not create the campaign."));
                return;
            }

            created ();
            close ();
        }

        // Template tokens that don't match any column of the chosen sheet.
        private string[] unknown_fields (Template template, string[] columns) {
            var available = new HashTable<string, bool> (str_hash, str_equal);
            foreach (var col in columns) {
                available.set (col, true);
            }
            var seen = new HashTable<string, bool> (str_hash, str_equal);
            string[] unknown = {};
            foreach (var t in Substitution.find_tokens (template.subject)) {
                if (!available.contains (t) && !seen.contains (t)) {
                    seen.set (t, true);
                    unknown += t;
                }
            }
            foreach (var t in Substitution.find_tokens (template.body_html)) {
                if (!available.contains (t) && !seen.contains (t)) {
                    seen.set (t, true);
                    unknown += t;
                }
            }
            return unknown;
        }

        private void toast (string text) {
            Ui.toast (this, text);
        }
    }
}
