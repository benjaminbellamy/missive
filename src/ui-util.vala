// SPDX-License-Identifier: GPL-3.0-or-later

namespace Missive {
    // Shared UI helpers used across the entity views and dialogs, so the
    // status presentation, delete confirmation and toast lookup live in one
    // place instead of being copy-pasted per screen.
    namespace Ui {
        public delegate void ConfirmAction ();

        // All campaign status values, used to clear the badge's style classes.
        private const string[] CAMPAIGN_STATUSES = {
            CAMPAIGN_DRAFT, CAMPAIGN_RUNNING, CAMPAIGN_PAUSED,
            CAMPAIGN_STOPPED, CAMPAIGN_COMPLETED
        };

        public string campaign_status_label (string status) {
            switch (status) {
                case CAMPAIGN_RUNNING: return _("Running");
                case CAMPAIGN_PAUSED: return _("Paused");
                case CAMPAIGN_STOPPED: return _("Stopped");
                case CAMPAIGN_COMPLETED: return _("Completed");
                default: return _("Draft");
            }
        }

        // Set a "status-badge" label's text and exclusive status style class.
        public void apply_status_badge (Gtk.Label label, string status) {
            foreach (var s in CAMPAIGN_STATUSES) {
                label.remove_css_class (s);
            }
            label.add_css_class (status);
            label.label = campaign_status_label (status);
        }

        public string recipient_status_text (CampaignRecipient r) {
            switch (r.status) {
                case RECIPIENT_SENT:
                    if (r.sent_at > 0) {
                        var when = new DateTime.from_unix_local (r.sent_at);
                        return _("Sent · %s").printf (when.format ("%x %H:%M"));
                    }
                    return _("Sent");
                case RECIPIENT_SENDING: return _("Sending…");
                case RECIPIENT_FAILED: return _("Failed: %s").printf (r.error_text);
                case RECIPIENT_SKIPPED: return _("Skipped: %s").printf (r.error_text);
                default: return _("Pending");
            }
        }

        // Remove every row from a list box.
        public void clear_list (Gtk.ListBox list) {
            Gtk.Widget? child;
            while ((child = list.get_first_child ()) != null) {
                list.remove (child);
            }
        }

        // Standard destructive-confirmation dialog; runs action on confirm.
        public void confirm_delete (Gtk.Widget parent, string heading,
                                    string body, owned ConfirmAction action) {
            var dialog = new Adw.AlertDialog (heading, body);
            dialog.add_response ("cancel", _("Cancel"));
            dialog.add_response ("delete", _("Delete"));
            dialog.set_response_appearance ("delete",
                                            Adw.ResponseAppearance.DESTRUCTIVE);
            dialog.default_response = "cancel";
            dialog.close_response = "cancel";
            dialog.response.connect ((response) => {
                if (response == "delete") {
                    action ();
                }
            });
            dialog.present (parent);
        }

        // Show a transient message via the enclosing MainWindow, if any.
        public void toast (Gtk.Widget origin, string text) {
            var win = origin.get_root () as MainWindow;
            if (win != null) {
                win.show_toast (text);
            }
        }
    }
}
