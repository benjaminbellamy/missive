// SPDX-License-Identifier: GPL-3.0-or-later

namespace Missive {
    // Campaign detail: identity/sheet/subject/recipient-column/CC/BCC/delay,
    // status badge, live progress, and the per-recipient list. Drives the send
    // engine (run/pause/stop/continue/retry) and updates live as it runs. Send
    // test and Delete also work; CC/BCC stay editable while draft.
    [GtkTemplate (ui = "/fr/benjaminbellamy/missive/campaign-detail.ui")]
    public class CampaignDetail : Adw.Dialog {
        [GtkChild] private unowned Gtk.Label status_badge;
        [GtkChild] private unowned Gtk.Label counts_label;
        [GtkChild] private unowned Gtk.ProgressBar progress_bar;
        [GtkChild] private unowned Adw.ActionRow identity_value;
        [GtkChild] private unowned Adw.ActionRow sheet_value;
        [GtkChild] private unowned Adw.ActionRow subject_value;
        [GtkChild] private unowned Adw.ActionRow recipient_value;
        [GtkChild] private unowned Adw.ActionRow delay_value;
        [GtkChild] private unowned Adw.ActionRow stop_value;
        [GtkChild] private unowned Adw.ActionRow signature_value;
        [GtkChild] private unowned Adw.ActionRow unsubscribe_value;
        [GtkChild] private unowned Adw.EntryRow cc_row;
        [GtkChild] private unowned Adw.EntryRow bcc_row;
        [GtkChild] private unowned Gtk.ListBox recipient_list;
        [GtkChild] private unowned Gtk.Button run_button;
        [GtkChild] private unowned Gtk.Button continue_button;
        [GtkChild] private unowned Gtk.Button pause_button;
        [GtkChild] private unowned Gtk.Button stop_button;
        [GtkChild] private unowned Gtk.Button retry_button;
        [GtkChild] private unowned Gtk.Button delete_button;
        [GtkChild] private unowned Gtk.Button test_button;

        private Database db;
        private GLib.Settings settings;
        private CampaignEngine? engine;
        private Campaign campaign;
        private bool loading = false;
        private HashTable<int64?, Adw.ActionRow> row_map;
        private ulong h_recipient = 0;
        private ulong h_progress = 0;
        private ulong h_finished = 0;

        public CampaignDetail (Database db, GLib.Settings settings, Campaign campaign) {
            Object ();
            this.db = db;
            this.settings = settings;
            this.campaign = campaign;
            this.engine = ((Application) GLib.Application.get_default ()).engine;
            this.row_map = new HashTable<int64?, Adw.ActionRow> (int64_hash, int64_equal);
            title = campaign.name;

            cc_row.changed.connect (on_cc_changed);
            bcc_row.changed.connect (on_bcc_changed);
            test_button.clicked.connect (on_send_test);
            delete_button.clicked.connect (on_delete);
            run_button.clicked.connect (on_run);
            continue_button.clicked.connect (on_run);
            pause_button.clicked.connect (() => { if (engine != null) engine.pause (); });
            stop_button.clicked.connect (() => { if (engine != null) engine.stop (); });
            retry_button.clicked.connect (on_retry);

            if (engine != null) {
                h_recipient = engine.recipient_changed.connect ((cid, rid) => {
                    if (cid == campaign.id) update_one_row (rid);
                });
                h_progress = engine.progress.connect ((cid) => {
                    if (cid == campaign.id) refresh_live ();
                });
                h_finished = engine.finished.connect ((cid, msg) => {
                    if (cid == campaign.id) { refresh (); toast (msg); }
                });
            }
            this.closed.connect (disconnect_engine);

            refresh ();
        }

        private void disconnect_engine () {
            if (engine == null) {
                return;
            }
            if (h_recipient != 0) engine.disconnect (h_recipient);
            if (h_progress != 0) engine.disconnect (h_progress);
            if (h_finished != 0) engine.disconnect (h_finished);
            h_recipient = h_progress = h_finished = 0;
        }

        // --- population -------------------------------------------------------

        public void refresh () {
            loading = true;
            reload_campaign ();
            populate_details ();
            populate_recipients ();
            loading = false;
        }

        // Lightweight update during a run: status, buttons and progress only.
        private void refresh_live () {
            loading = true;
            reload_campaign ();
            populate_details ();
            update_progress ();
            loading = false;
        }

        private void reload_campaign () {
            try {
                var fresh = db.get_campaign (campaign.id);
                if (fresh != null) {
                    campaign = fresh;
                }
            } catch (DatabaseError e) {
                warning ("Could not reload campaign: %s", e.message);
            }
        }

        private void populate_details () {
            string identity_name = _("(deleted)");
            try {
                var identity = db.get_identity (campaign.identity_id);
                if (identity != null) {
                    identity_name = identity.name != "" ? identity.name : identity.from_email;
                }
            } catch (DatabaseError e) { }

            string sheet_name = _("(deleted)");
            try {
                var sheet = db.get_sheet (campaign.csv_sheet_id);
                if (sheet != null) {
                    sheet_name = sheet.name;
                }
            } catch (DatabaseError e) { }

            identity_value.subtitle = identity_name;
            sheet_value.subtitle = sheet_name;
            subject_value.subtitle = campaign.subject_snapshot;
            recipient_value.subtitle = campaign.recipient_column;
            delay_value.subtitle = _("%d s").printf (campaign.delay_seconds);
            stop_value.subtitle = campaign.stop_on_error ? _("Yes") : _("No");
            signature_value.subtitle = campaign.include_signature ? _("Yes") : _("No");
            unsubscribe_value.subtitle = campaign.unsubscribe_lang == ""
                ? _("None") : Lang.endonym (campaign.unsubscribe_lang);

            cc_row.text = campaign.cc;
            bcc_row.text = campaign.bcc;
            bool is_draft = campaign.status == CAMPAIGN_DRAFT;
            cc_row.sensitive = is_draft;
            bcc_row.sensitive = is_draft;

            Ui.apply_status_badge (status_badge, campaign.status);
            update_buttons ();
        }

        private void populate_recipients () {
            Ui.clear_list (recipient_list);
            row_map.remove_all ();

            CampaignRecipient[] recipients = {};
            try {
                recipients = db.recipients_for_campaign (campaign.id);
            } catch (DatabaseError e) {
                warning ("Could not load recipients: %s", e.message);
            }

            foreach (var r in recipients) {
                var row = make_recipient_row (r);
                row_map.set (r.id, row);
                recipient_list.append (row);
            }
            update_progress ();
        }

        private void update_one_row (int64 recipient_id) {
            var row = row_map.lookup (recipient_id);
            if (row != null) {
                try {
                    var r = db.get_recipient (recipient_id);
                    if (r != null) {
                        row.subtitle = Ui.recipient_status_text (r);
                    }
                } catch (DatabaseError e) { }
            }
            update_progress ();
        }

        private void update_progress () {
            RecipientCounts c = {};
            try {
                c = db.count_recipients_by_status (campaign.id);
            } catch (DatabaseError e) { }

            int done = c.sent + c.failed + c.skipped;
            progress_bar.fraction = c.total > 0 ? (double) done / c.total : 0.0;
            progress_bar.text = _("%d sent / %d").printf (c.sent, c.total);
            counts_label.label = _("%d failed · %d skipped · %d pending").printf (
                c.failed, c.skipped, c.pending);
        }

        private Adw.ActionRow make_recipient_row (CampaignRecipient r) {
            return new Adw.ActionRow () {
                title = r.to_address != "" ? r.to_address : _("(no address)"),
                subtitle = Ui.recipient_status_text (r)
            };
        }

        private void update_buttons () {
            int failed = 0;
            try { failed = db.count_recipients (campaign.id, RECIPIENT_FAILED); }
            catch (DatabaseError e) { }

            var s = campaign.status;
            run_button.visible = s == CAMPAIGN_DRAFT;
            continue_button.visible = s == CAMPAIGN_PAUSED || s == CAMPAIGN_STOPPED;
            pause_button.visible = s == CAMPAIGN_RUNNING;
            stop_button.visible = s == CAMPAIGN_RUNNING || s == CAMPAIGN_PAUSED;
            retry_button.visible = (s == CAMPAIGN_STOPPED || s == CAMPAIGN_COMPLETED)
                && failed > 0;
            delete_button.visible = s == CAMPAIGN_DRAFT || s == CAMPAIGN_STOPPED
                || s == CAMPAIGN_COMPLETED;
        }

        // --- actions ----------------------------------------------------------

        private void on_run () {
            var unknown = unknown_tokens ();
            if (unknown.length > 0) {
                var dialog = new Adw.AlertDialog (_("Unmatched Fields"),
                    _("These fields have no matching column and will appear literally: %s")
                        .printf (string.joinv (", ", unknown)));
                dialog.add_response ("cancel", _("Cancel"));
                dialog.add_response ("run", _("Run Anyway"));
                dialog.set_response_appearance ("run", Adw.ResponseAppearance.SUGGESTED);
                dialog.default_response = "cancel";
                dialog.close_response = "cancel";
                dialog.response.connect ((response) => {
                    if (response == "run") start_run ();
                });
                dialog.present (this);
                return;
            }
            start_run ();
        }

        private void start_run () {
            if (engine != null && !engine.run (campaign.id)) {
                toast (_("Another campaign is already running."));
            }
        }

        // Tokens in the snapshot subject/body with no matching column in the
        // recipients' snapshotted rows.
        private string[] unknown_tokens () {
            var available = new HashTable<string, bool> (str_hash, str_equal);
            try {
                var recipients = db.recipients_for_campaign (campaign.id);
                if (recipients.length > 0) {
                    var row = JsonUtil.string_to_object (recipients[0].row_data_json);
                    foreach (var key in row.get_keys ()) {
                        available.set (key, true);
                    }
                }
            } catch (DatabaseError e) { }

            var seen = new HashTable<string, bool> (str_hash, str_equal);
            string[] unknown = {};
            foreach (var t in Substitution.find_tokens (campaign.subject_snapshot)) {
                if (!available.contains (t) && !seen.contains (t)) {
                    seen.set (t, true);
                    unknown += t;
                }
            }
            foreach (var t in Substitution.find_tokens (campaign.body_html_snapshot)) {
                if (!available.contains (t) && !seen.contains (t)) {
                    seen.set (t, true);
                    unknown += t;
                }
            }
            return unknown;
        }

        private void on_retry () {
            try {
                db.reset_failed_recipients (campaign.id);
            } catch (DatabaseError e) {
                warning ("Could not reset failed recipients: %s", e.message);
            }
            refresh ();
            start_run ();
        }

        private void on_cc_changed () {
            if (loading) {
                return;
            }
            campaign.cc = cc_row.text.strip ();
            persist ();
        }

        private void on_bcc_changed () {
            if (loading) {
                return;
            }
            campaign.bcc = bcc_row.text.strip ();
            persist ();
        }

        private void persist () {
            try {
                db.update_campaign (campaign);
            } catch (DatabaseError e) {
                warning ("Could not update campaign: %s", e.message);
            }
        }

        private void on_send_test () {
            var test_to = settings.get_string ("test-recipient").strip ();
            if (test_to == "") {
                toast (_("Set a test recipient address in Preferences first."));
                return;
            }
            Identity? identity = null;
            try {
                identity = db.get_identity (campaign.identity_id);
            } catch (DatabaseError e) { }
            if (identity == null) {
                toast (_("The campaign's identity no longer exists."));
                return;
            }
            if (SecretStore.lookup_password (identity.id) == null) {
                toast (_("No password is stored for the identity."));
                return;
            }

            var values = new HashTable<string, string> (str_hash, str_equal);
            try {
                var recipients = db.recipients_for_campaign (campaign.id);
                if (recipients.length > 0) {
                    values = JsonUtil.string_to_object (recipients[0].row_data_json);
                }
            } catch (DatabaseError e) { }

            var unknown = new HashTable<string, bool> (str_hash, str_equal);
            var message = MessageBuilder.compose (identity,
                campaign.subject_snapshot, campaign.body_html_snapshot,
                values, test_to, {}, unknown, campaign.include_signature,
                campaign.unsubscribe_lang);
            var mime = MessageBuilder.to_mime_string (message);
            var owned_identity = identity;

            toast (_("Sending test message…"));
            new Thread<bool> ("campaign-test", () => {
                string? error = SmtpSender.send (owned_identity, mime, { test_to });
                Idle.add (() => {
                    if (error == null) {
                        toast (_("Test message sent to %s").printf (test_to));
                    } else {
                        toast (_("Test send failed: %s").printf (error));
                    }
                    return Source.REMOVE;
                });
                return true;
            });
        }

        private void on_delete () {
            Ui.confirm_delete (this, _("Delete Campaign?"),
                _("“%s” and its recipients will be permanently removed.").printf (
                    campaign.name),
                () => {
                    try {
                        db.delete_campaign (campaign.id);
                    } catch (DatabaseError e) {
                        warning ("Could not delete campaign: %s", e.message);
                        return;
                    }
                    close ();
                });
        }

        private void toast (string text) {
            Ui.toast (this, text);
        }
    }
}
