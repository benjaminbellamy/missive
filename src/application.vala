// SPDX-License-Identifier: GPL-3.0-or-later

namespace Missive {
    public class Application : Adw.Application {
        // Global app data store, opened once at startup.
        public Database? database { get; private set; default = null; }
        // Global preferences.
        public GLib.Settings settings { get; private set; }
        // The single send engine (one campaign runs at a time).
        public CampaignEngine? engine { get; private set; default = null; }

        public Application () {
            Object (
                application_id: Config.APP_ID,
                flags: ApplicationFlags.DEFAULT_FLAGS,
                resource_base_path: Config.RESOURCE_BASE
            );
        }

        construct {
            ActionEntry[] action_entries = {
                { "about", on_about_action },
                { "preferences", on_preferences_action },
                { "help", on_help_action },
                { "new", on_new_action },
                { "quit", quit }
            };
            add_action_entries (action_entries, this);
            set_accels_for_action ("app.quit", { "<primary>q" });
            set_accels_for_action ("app.preferences", { "<primary>comma" });
            set_accels_for_action ("app.new", { "<primary>n" });
            set_accels_for_action ("app.help", { "F1" });
        }

        public override void startup () {
            base.startup ();

            // Compact style for the template editor's CSV field chips.
            var provider = new Gtk.CssProvider ();
            provider.load_from_string (
                ".field-chip { padding: 1px 7px; min-height: 0; font-size: 0.85em; }"
                + ".status-badge { padding: 1px 9px; border-radius: 9px;"
                + " font-size: 0.78em; font-weight: bold; }"
                + ".status-badge.draft { background: alpha(@window_fg_color, 0.12); }"
                + ".status-badge.running { background: @accent_bg_color; color: @accent_fg_color; }"
                + ".status-badge.paused { background: @warning_bg_color; color: @warning_fg_color; }"
                + ".status-badge.stopped { background: alpha(@window_fg_color, 0.15); }"
                + ".status-badge.completed { background: @success_bg_color; color: @success_fg_color; }");
            Gtk.StyleContext.add_provider_for_display (
                Gdk.Display.get_default (), provider,
                Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);

            settings = new GLib.Settings (Config.APP_ID);

            try {
                var data_dir = Environment.get_user_data_dir ();
                DirUtils.create_with_parents (data_dir, 0700);
                var path = Path.build_filename (data_dir, "missive.db");
                database = new Database (path);
                // Recover from any run interrupted by a crash or quit.
                database.reset_interrupted_runs ();
                engine = new CampaignEngine (path);
            } catch (DatabaseError e) {
                critical ("Could not initialize database: %s", e.message);
            }
        }

        public override void activate () {
            base.activate ();
            var win = active_window;
            if (win == null) {
                win = new MainWindow (this);
            }
            win.present ();
        }

        private void on_about_action () {
            var about = new Adw.AboutDialog () {
                application_name = "Missive",
                application_icon = Config.APP_ID,
                developer_name = "Benjamin Bellamy",
                version = Config.VERSION,
                license_type = Gtk.License.GPL_3_0,
                copyright = "© 2026 Benjamin Bellamy",
                website = "https://github.com/benjaminbellamy/missive",
                issue_url = "https://github.com/benjaminbellamy/missive/issues",
                comments = _("Run personalized email campaigns by mail merge over SMTP.")
            };
            about.developers = { "Benjamin Bellamy" };
            about.translator_credits = _("translator-credits");
            about.present (active_window);
        }

        private void on_help_action () {
            new HelpDialog ().present (active_window);
        }

        private void on_new_action () {
            var win = active_window as MainWindow;
            if (win != null) {
                win.trigger_new ();
            }
        }

        private void on_preferences_action () {
            var dialog = new Adw.PreferencesDialog ();
            var page = new Adw.PreferencesPage () {
                title = _("General"),
                icon_name = "preferences-system-symbolic"
            };

            var lang_group = new Adw.PreferencesGroup ();
            // Endonyms are shown in their own language and are not translated.
            string[] lang_codes = { "", "en", "fr", "de", "it", "es", "nl" };
            var lang_row = new Adw.ComboRow () {
                title = _("Language"),
                subtitle = _("Takes effect after restart"),
                model = new Gtk.StringList ({
                    _("Same as System"),
                    "English", "Français", "Deutsch",
                    "Italiano", "Español", "Nederlands"
                })
            };
            var current_lang = settings.get_string ("language");
            for (uint i = 0; i < lang_codes.length; i++) {
                if (lang_codes[i] == current_lang) {
                    lang_row.selected = i;
                    break;
                }
            }
            lang_row.notify["selected"].connect (() => {
                settings.set_string ("language", lang_codes[lang_row.selected]);
            });
            lang_group.add (lang_row);
            page.add (lang_group);

            var group = new Adw.PreferencesGroup () {
                title = _("Campaign Defaults"),
                description = _("These values seed new campaigns and the test send.")
            };

            var delay = new Adw.SpinRow.with_range (0, 3600, 1) {
                title = _("Delay Between Messages"),
                subtitle = _("Seconds to wait after each message")
            };
            delay.value = settings.get_int ("default-delay-seconds");
            delay.notify["value"].connect (() => {
                settings.set_int ("default-delay-seconds", (int) delay.value);
            });

            var stop = new Adw.SwitchRow () {
                title = _("Stop on First Error"),
                subtitle = _("Halt a campaign as soon as a message fails")
            };
            settings.bind ("default-stop-on-error", stop, "active",
                           SettingsBindFlags.DEFAULT);

            var test = new Adw.EntryRow () {
                title = _("Test Recipient Address")
            };
            settings.bind ("test-recipient", test, "text",
                           SettingsBindFlags.DEFAULT);

            var cc = new Adw.EntryRow () {
                title = _("Default Cc")
            };
            settings.bind ("default-cc", cc, "text", SettingsBindFlags.DEFAULT);

            var bcc = new Adw.EntryRow () {
                title = _("Default Bcc")
            };
            settings.bind ("default-bcc", bcc, "text", SettingsBindFlags.DEFAULT);

            group.add (delay);
            group.add (stop);
            group.add (test);
            group.add (cc);
            group.add (bcc);
            page.add (group);
            dialog.add (page);
            dialog.present (active_window);
        }
    }
}
