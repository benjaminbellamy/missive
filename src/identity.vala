// SPDX-License-Identifier: GPL-3.0-or-later

namespace Missive {
    // SMTP encryption modes, stored as text in the database.
    public const string ENCRYPTION_SMTPS = "smtps";
    public const string ENCRYPTION_STARTTLS = "starttls";
    public const string ENCRYPTION_NONE = "none";

    // A sender identity. The SMTP password is never stored here; it lives in
    // libsecret keyed by this identity's id (see SecretStore).
    public class Identity : Object {
        public int64 id { get; set; default = 0; }
        public string name { get; set; default = ""; }
        public string from_name { get; set; default = ""; }
        public string from_email { get; set; default = ""; }
        public string smtp_host { get; set; default = ""; }
        public int smtp_port { get; set; default = 465; }
        public string smtp_encryption { get; set; default = ENCRYPTION_SMTPS; }
        public string smtp_username { get; set; default = ""; }
        public string signature_html { get; set; default = ""; }
    }
}
