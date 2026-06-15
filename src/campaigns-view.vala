// SPDX-License-Identifier: GPL-3.0-or-later

namespace Missive {
    // The Campaigns section: an empty state or a boxed list of campaigns, each
    // showing a status badge and "sent / total" progress. The header New action
    // opens the creation flow; activating a row opens the detail dialog.
    [GtkTemplate (ui = "/fr/bellamy/missive/campaigns-view.ui")]
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

            row.activated.connect (() => open_detail (campaign));
            return row;
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
