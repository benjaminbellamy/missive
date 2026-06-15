// SPDX-License-Identifier: GPL-3.0-or-later

namespace Missive {
    // Lightweight "looks like an email" check used to decide which CSV rows are
    // usable recipients. Not a full RFC 5322 validator — just enough to skip
    // empty cells and obviously malformed addresses.
    public class EmailUtil : Object {
        public static bool is_valid (string address) {
            var a = address.strip ();
            if (a == "" || a.contains (" ")) {
                return false;
            }
            int at = a.index_of_char ('@');
            if (at <= 0) {
                return false;
            }
            // Exactly one '@'.
            if (a.index_of_char ('@', at + 1) >= 0) {
                return false;
            }
            var domain = a.substring (at + 1);
            if (domain.length == 0 || !domain.contains (".")
                || domain.has_prefix (".") || domain.has_suffix (".")) {
                return false;
            }
            return true;
        }
    }
}
