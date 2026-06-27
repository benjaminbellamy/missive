// SPDX-License-Identifier: GPL-3.0-or-later

namespace Missive {
    [GtkTemplate (ui = "/fr/benjaminbellamy/missive/window.ui")]
    public class MainWindow : Adw.ApplicationWindow {
        [GtkChild] private unowned Gtk.ListBox sidebar_list;
        [GtkChild] private unowned Gtk.Stack content_stack;
        [GtkChild] private unowned Adw.NavigationSplitView split_view;
        [GtkChild] private unowned Adw.NavigationPage content_page;
        [GtkChild] private unowned Gtk.Button new_button;
        [GtkChild] private unowned Adw.ButtonContent new_button_content;
        [GtkChild] private unowned Gtk.Button import_html_button;
        [GtkChild] private unowned Adw.Bin campaigns_container;
        [GtkChild] private unowned Adw.Bin identities_container;
        [GtkChild] private unowned Adw.Bin sheets_container;
        [GtkChild] private unowned Adw.Bin templates_container;
        [GtkChild] private unowned Adw.ToastOverlay toast_overlay;

        private CampaignsView? campaigns_view = null;
        private IdentitiesView? identities_view = null;
        private CsvSheetsView? csv_sheets_view = null;
        private TemplatesView? templates_view = null;

        public MainWindow (Application app) {
            Object (application: app);
        }

        construct {
            var app = (Application) GLib.Application.get_default ();
            if (app.database != null) {
                campaigns_view = new CampaignsView (app.database, app.settings);
                campaigns_container.child = campaigns_view;

                identities_view = new IdentitiesView (app.database);
                identities_container.child = identities_view;

                csv_sheets_view = new CsvSheetsView (app.database);
                sheets_container.child = csv_sheets_view;

                templates_view = new TemplatesView (app.database);
                templates_container.child = templates_view;
            }

            sidebar_list.row_selected.connect (on_row_selected);
            new_button.clicked.connect (on_new_clicked);
            import_html_button.clicked.connect (() => {
                if (templates_view != null) {
                    templates_view.import_html ();
                }
            });

            var first = sidebar_list.get_row_at_index (0);
            if (first != null) {
                sidebar_list.select_row (first);
            }
        }

        // Show a transient message over the content area.
        public void show_toast (string text) {
            toast_overlay.add_toast (new Adw.Toast (text));
        }

        private void on_row_selected (Gtk.ListBoxRow? row) {
            if (row == null) {
                return;
            }
            var name = row.name;
            if (name == null) {
                return;
            }

            content_stack.visible_child_name = name;
            content_page.title = section_title (name);
            configure_action_button (name);
            split_view.show_content = true;
        }

        // The header's primary button changes per section (create vs import).
        private void configure_action_button (string section) {
            // The "Import HTML" action only applies to templates.
            import_html_button.visible = section == "templates";
            switch (section) {
                case "campaigns":
                    new_button.visible = true;
                    new_button.tooltip_text = _("New Campaign");
                    new_button_content.icon_name = "list-add-symbolic";
                    new_button_content.label = _("New Campaign");
                    break;
                case "identities":
                    new_button.visible = true;
                    new_button.tooltip_text = _("New Identity");
                    new_button_content.icon_name = "list-add-symbolic";
                    new_button_content.label = _("New");
                    break;
                case "sheets":
                    new_button.visible = true;
                    new_button.tooltip_text = _("Import CSV");
                    new_button_content.icon_name = "document-open-symbolic";
                    new_button_content.label = _("Import");
                    break;
                case "templates":
                    new_button.visible = true;
                    new_button.tooltip_text = _("New Template");
                    new_button_content.icon_name = "list-add-symbolic";
                    new_button_content.label = _("New");
                    break;
                default:
                    new_button.visible = false;
                    break;
            }
        }

        // Invoked by the Ctrl+N accelerator (app.new).
        public void trigger_new () {
            on_new_clicked ();
        }

        private void on_new_clicked () {
            switch (content_stack.visible_child_name) {
                case "campaigns":
                    if (campaigns_view != null) {
                        campaigns_view.new_campaign ();
                    }
                    break;
                case "identities":
                    if (identities_view != null) {
                        identities_view.new_identity ();
                    }
                    break;
                case "sheets":
                    if (csv_sheets_view != null) {
                        csv_sheets_view.import_sheet ();
                    }
                    break;
                case "templates":
                    if (templates_view != null) {
                        templates_view.new_template ();
                    }
                    break;
                default:
                    break;
            }
        }

        private string section_title (string name) {
            switch (name) {
                case "campaigns":
                    return _("Mailing Campaigns");
                case "templates":
                    return _("Message Templates");
                case "sheets":
                    return _("Address Sheets");
                case "identities":
                    return _("Sender Identities");
                default:
                    return _("Missive");
            }
        }
    }
}
