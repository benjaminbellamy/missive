// SPDX-License-Identifier: GPL-3.0-or-later

namespace Missive {
    // Sends a composed message through the libcurl SMTP shim, resolving the
    // identity's password from the keyring and normalizing the payload for SMTP
    // (CRLF line endings and dot-stuffing). Blocks — call off the main thread.
    public class SmtpSender : Object {

        // Normalize a MIME string for SMTP: CRLF line endings and dot-stuffing.
        public static string normalize (string mime) {
            var data = mime.replace ("\r\n", "\n").replace ("\n", "\r\n");
            data = data.replace ("\r\n.", "\r\n..");
            if (data.has_prefix (".")) {
                data = "." + data;
            }
            return data;
        }

        // One-shot send (used by the test send). Returns null on success.
        public static string? send (Identity identity, string mime,
                                    string[] envelope_recipients) {
            var password = SecretStore.lookup_password (identity.id) ?? "";
            var data = normalize (mime);
            return MissiveSmtp.send (
                identity.smtp_host, identity.smtp_port, identity.smtp_encryption,
                identity.smtp_username, password, identity.from_email,
                envelope_recipients, data, data.length);
        }
    }
}
