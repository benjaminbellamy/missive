// SPDX-License-Identifier: GPL-3.0-or-later

public static int main (string[] args) {
    // Honor the user's language choice before gettext is initialized. An empty
    // value means "follow the system language"; gettext then falls back to the
    // English source strings when the system language has no catalog.
    var prefs = new GLib.Settings (Missive.Config.APP_ID);
    var lang = prefs.get_string ("language");
    if (lang != "") {
        GLib.Environment.set_variable ("LANGUAGE", lang, true);
    }

    // Apply the locale. A single LC_ALL call can fail outright when the host
    // exports an LC_* category (e.g. LC_NUMERIC=fr_FR.UTF-8) whose locale is
    // not present in the runtime; that would drop messages to the "C" locale
    // and make glibc ignore LANGUAGE, defeating the language choice above.
    // Re-applying the categories we rely on keeps message translation working.
    GLib.Intl.setlocale (GLib.LocaleCategory.ALL, "");
    GLib.Intl.setlocale (GLib.LocaleCategory.CTYPE, "");
    GLib.Intl.setlocale (GLib.LocaleCategory.MESSAGES, "");

    GLib.Intl.bindtextdomain (Missive.Config.GETTEXT_PACKAGE, Missive.Config.LOCALEDIR);
    GLib.Intl.bind_textdomain_codeset (Missive.Config.GETTEXT_PACKAGE, "UTF-8");
    GLib.Intl.textdomain (Missive.Config.GETTEXT_PACKAGE);

    GMime.init ();

    var app = new Missive.Application ();
    return app.run (args);
}
