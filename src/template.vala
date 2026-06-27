// SPDX-License-Identifier: GPL-3.0-or-later

namespace Missive {
    // A reusable message template. Timestamps are Unix seconds (UTC).
    public class Template : Object {
        public int64 id { get; set; default = 0; }
        public string name { get; set; default = ""; }
        public string subject { get; set; default = ""; }
        public string body_html { get; set; default = ""; }
        // Empty means no unsubscribe link; otherwise a language code (see Lang).
        // The {unsubscribe} token in the body is replaced with the link at send.
        public string unsubscribe_lang { get; set; default = ""; }
        public int64 created_at { get; set; default = 0; }
        public int64 updated_at { get; set; default = 0; }
    }
}
