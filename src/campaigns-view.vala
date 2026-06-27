// SPDX-License-Identifier: GPL-3.0-or-later

namespace Missive {
    // The Campaigns section: an empty state or a boxed list of campaigns, each
    // showing a status badge and "sent / total" progress. The header New action
    // opens the creation flow; activating a row opens the detail dialog.
    [GtkTemplate (ui = "/fr/benjaminbellamy/missive/campaigns-view.ui")]
    public class CampaignsView : Adw.Bin {
        [GtkChild] private unowned Gtk.Stack view_stack;
        [GtkChild] private unowned Gtk.ListBox campaign_list;

        private Database db;
        private GLib.Settings settings;

        public CampaignsView (Database db, GLib.Settings settings) {
            Object ();
            this.db = db;
            this.settings = settings;

            // Reflect run start/finish (status badges, counts) in the list.
            var engine = ((Application) GLib.Application.get_default ()).engine;
            if (engine != null) {
                engine.progress.connect ((cid) => refresh ());
                engine.finished.connect ((cid, msg) => refresh ());
            }

            refresh ();
        }

        public void refresh () {
            Ui.clear_list (campaign_list);

            Campaign[] items = {};
            try {
                items = db.all_campaigns ();
            } catch (DatabaseError e) {
                warning ("Could not load campaigns: %s", e.message);
            }

            if (items.length == 0) {
                view_stack.visible_child_name = "empty";
                return;
            }

            view_stack.visible_child_name = "list";
            foreach (var campaign in items) {
                campaign_list.append (make_row (campaign));
            }
        }

        private Gtk.Widget make_row (Campaign campaign) {
            RecipientCounts c = {};
            try {
                c = db.count_recipients_by_status (campaign.id);
            } catch (DatabaseError e) { }

            var row = new Adw.ActionRow () {
                title = campaign.name,
                subtitle = _("%d / %d sent").printf (c.sent, c.total),
                activatable = true
            };

            var badge = new Gtk.Label ("") {
                valign = Gtk.Align.CENTER
            };
            badge.add_css_class ("status-badge");
            Ui.apply_status_badge (badge, campaign.status);
            row.add_suffix (badge);

            var duplicate = new Gtk.Button.from_icon_name ("edit-copy-symbolic") {
                valign = Gtk.Align.CENTER,
                tooltip_text = _("Duplicate")
            };
            duplicate.add_css_class ("flat");
            duplicate.clicked.connect (() => duplicate_campaign (campaign));
            row.add_suffix (duplicate);

            // Deletable only when not actively running/paused.
            if (campaign.status == CAMPAIGN_DRAFT || campaign.status == CAMPAIGN_STOPPED
                || campaign.status == CAMPAIGN_COMPLETED) {
                var delete = new Gtk.Button.from_icon_name ("user-trash-symbolic") {
                    valign = Gtk.Align.CENTER,
                    tooltip_text = _("Delete")
                };
                delete.add_css_class ("flat");
                delete.clicked.connect (() => confirm_delete (campaign));
                row.add_suffix (delete);
            }

            row.activated.connect (() => open_detail (campaign));
            return row;
        }

        private void confirm_delete (Campaign campaign) {
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
                    refresh ();
                });
        }

        // Duplicate a campaign as a fresh draft: copy the snapshot and the
        // recipients, resetting send progress (skipped rows stay skipped).
        private void duplicate_campaign (Campaign campaign) {
            var now = new DateTime.now_utc ().to_unix ();
            var copy = new Campaign () {
                name = _("%s (copy)").printf (campaign.name),
                status = CAMPAIGN_DRAFT,
                identity_id = campaign.identity_id,
                csv_sheet_id = campaign.csv_sheet_id,
                recipient_column = campaign.recipient_column,
                cc = campaign.cc,
                bcc = campaign.bcc,
                subject_snapshot = campaign.subject_snapshot,
                body_html_snapshot = campaign.body_html_snapshot,
                delay_seconds = campaign.delay_seconds,
                stop_on_error = campaign.stop_on_error,
                created_at = now
            };
            try {
                db.insert_campaign (copy);
                CampaignRecipient[] recipients = {};
                foreach (var r in db.recipients_for_campaign (campaign.id)) {
                    bool skipped = r.status == RECIPIENT_SKIPPED;
                    recipients += new CampaignRecipient () {
                        idx = r.idx,
                        to_address = r.to_address,
                        row_data_json = r.row_data_json,
                        status = skipped ? RECIPIENT_SKIPPED : RECIPIENT_PENDING,
                        error_text = skipped ? r.error_text : ""
                    };
                }
                db.insert_recipients (copy.id, recipients);
            } catch (DatabaseError e) {
                warning ("Could not duplicate campaign: %s", e.message);
                return;
            }
            refresh ();
        }

        public void new_campaign () {
            var dialog = new CampaignDialog (db, settings);
            dialog.created.connect (refresh);
            dialog.present (get_root () as Gtk.Widget);
        }

        private void open_detail (Campaign campaign) {
            var dialog = new CampaignDetail (db, settings, campaign);
            // Refresh the list when the detail closes (status/delete changes).
            dialog.closed.connect (refresh);
            dialog.present (get_root () as Gtk.Widget);
        }
    }
}
