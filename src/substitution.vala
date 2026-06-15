// SPDX-License-Identifier: GPL-3.0-or-later

namespace Missive {
    // Replaces {column_name} tokens with a recipient's values.
    //  - Token names match column names case-sensitively.
    //  - An unknown token is left literal and recorded in `unknown`.
    //  - {{ and }} render as single braces.
    //  - When escape_html is true, the inserted VALUE is HTML-escaped
    //    (& < > "); the surrounding template text is never altered. The subject
    //    (a plain-text header) is substituted with escape_html = false.
    public class Substitution : Object {

        public static string apply (string text,
                                    HashTable<string, string> values,
                                    bool escape_html,
                                    HashTable<string, bool> unknown) {
            var sb = new StringBuilder ();
            unowned uint8[] data = text.data;
            int n = text.length;
            int i = 0;

            while (i < n) {
                uint8 c = data[i];
                if (c == '{') {
                    if (i + 1 < n && data[i + 1] == '{') {
                        sb.append_c ('{');
                        i += 2;
                        continue;
                    }
                    // Find the closing brace, but bail on a nested '{'.
                    int j = -1;
                    for (int k = i + 1; k < n; k++) {
                        if (data[k] == '}') { j = k; break; }
                        if (data[k] == '{') { break; }
                    }
                    if (j < 0) {
                        sb.append_c ('{');
                        i++;
                        continue;
                    }
                    var nb = new StringBuilder ();
                    for (int k = i + 1; k < j; k++) {
                        nb.append_c ((char) data[k]);
                    }
                    string name = nb.str;
                    if (values.contains (name)) {
                        string val = values.lookup (name);
                        sb.append (escape_html ? escape_value (val) : val);
                    } else {
                        unknown.replace (name, true);
                        sb.append_c ('{');
                        sb.append (name);
                        sb.append_c ('}');
                    }
                    i = j + 1;
                } else if (c == '}') {
                    if (i + 1 < n && data[i + 1] == '}') {
                        sb.append_c ('}');
                        i += 2;
                        continue;
                    }
                    sb.append_c ('}');
                    i++;
                } else {
                    sb.append_c ((char) c);
                    i++;
                }
            }
            return sb.str;
        }

        // Distinct {token} names referenced in the text (ignoring {{ }} and
        // unterminated braces), for pre-run validation against the columns.
        public static string[] find_tokens (string text) {
            var seen = new HashTable<string, bool> (str_hash, str_equal);
            string[] result = {};
            unowned uint8[] data = text.data;
            int n = text.length;
            int i = 0;
            while (i < n) {
                uint8 c = data[i];
                if (c == '{') {
                    if (i + 1 < n && data[i + 1] == '{') {
                        i += 2;
                        continue;
                    }
                    int j = -1;
                    for (int k = i + 1; k < n; k++) {
                        if (data[k] == '}') { j = k; break; }
                        if (data[k] == '{') { break; }
                    }
                    if (j < 0) {
                        i++;
                        continue;
                    }
                    var nb = new StringBuilder ();
                    for (int k = i + 1; k < j; k++) {
                        nb.append_c ((char) data[k]);
                    }
                    if (!seen.contains (nb.str)) {
                        seen.set (nb.str, true);
                        result += nb.str;
                    }
                    i = j + 1;
                } else if (c == '}') {
                    i += (i + 1 < n && data[i + 1] == '}') ? 2 : 1;
                } else {
                    i++;
                }
            }
            return result;
        }

        private static string escape_value (string s) {
            return s.replace ("&", "&amp;")
                    .replace ("<", "&lt;")
                    .replace (">", "&gt;")
                    .replace ("\"", "&quot;");
        }
    }
}
