// SPDX-License-Identifier: GPL-3.0-or-later

namespace Missive {
    // The set of languages Missive ships, and small helpers shared by the
    // language picker, the campaign unsubscribe-link picker and the message
    // builder. Endonyms are each language's own name and are never translated.
    namespace Lang {

        public const string[] CODES = { "en", "fr", "de", "it", "es", "nl" };
        public const string[] ENDONYMS = {
            "English", "Français", "Deutsch", "Italiano", "Español", "Nederlands"
        };
        // Unsubscribe link text and mailto subject per language, aligned to CODES.
        // Index 0 (English) is the fallback for an unknown code.
        private const string[] UNSUB_LABELS = {
            "Unsubscribe", "Se désabonner", "Abbestellen",
            "Annulla iscrizione", "Cancelar suscripción", "Afmelden"
        };
        private const string[] UNSUB_SUBJECTS = {
            "Unsubscribe", "Désabonnement", "Abbestellen",
            "Annulla iscrizione", "Cancelar suscripción", "Afmelden"
        };

        // Position of a code in CODES, or -1 if unknown.
        private int index_of (string code) {
            for (int i = 0; i < CODES.length; i++) {
                if (CODES[i] == code) {
                    return i;
                }
            }
            return -1;
        }

        // A language's own name, or the code itself if unknown.
        public string endonym (string code) {
            int i = index_of (code);
            return i < 0 ? code : ENDONYMS[i];
        }

        public bool is_supported (string code) {
            return code in CODES;
        }

        // Labels and codes for a language picker: a leading sentinel
        // (code "", label first_label) followed by one entry per shipped
        // language. The codes array is returned through `codes`, parallel to the
        // returned labels, so the caller can map a selection back to a code.
        public string[] picker_labels (string first_label, out string[] codes) {
            string[] c = { "" };
            string[] labels = { first_label };
            foreach (var code in CODES) {
                c += code;
                labels += endonym (code);
            }
            codes = c;
            return labels;
        }

        // The effective UI language code: the app's explicit Language choice when
        // set, otherwise the best match from the system locale, falling back to
        // English. Always one of CODES.
        public string current (GLib.Settings settings) {
            string chosen = settings.get_string ("language");
            if (chosen != "" && is_supported (chosen)) {
                return chosen;
            }
            foreach (var name in GLib.Intl.get_language_names ()) {
                string two = name.length >= 2 ? name.substring (0, 2).down () : name;
                if (is_supported (two)) {
                    return two;
                }
            }
            return "en";
        }

        // Link text for an unsubscribe link, in the given language (independent
        // of the running UI locale, so it cannot use gettext).
        public string unsubscribe_label (string code) {
            int i = index_of (code);
            return UNSUB_LABELS[i < 0 ? 0 : i];
        }

        // The mailto subject for an unsubscribe link, in the given language.
        public string unsubscribe_subject (string code) {
            int i = index_of (code);
            return UNSUB_SUBJECTS[i < 0 ? 0 : i];
        }
    }
}
