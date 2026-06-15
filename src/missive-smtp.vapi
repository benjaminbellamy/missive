// SPDX-License-Identifier: GPL-3.0-or-later

[CCode (cheader_filename = "missive-smtp.h")]
namespace MissiveSmtp {
    // Returns null on success, or an error message on failure.
    [CCode (cname = "missive_smtp_test")]
    public string? test (string host, int port, string encryption,
                         string username, string password);

    // Send one serialized message. Returns null on success, else an error.
    [CCode (cname = "missive_smtp_send")]
    public string? send (string host, int port, string encryption,
                         string username, string password, string mail_from,
                         string[] recipients, string message, size_t message_len);

    // A reusable connection for a campaign run.
    [Compact]
    [CCode (cname = "MissiveSmtpSession", free_function = "missive_smtp_close")]
    public class Session {
        [CCode (cname = "missive_smtp_open")]
        public Session (string host, int port, string encryption,
                        string username, string password);

        [CCode (cname = "missive_smtp_session_send")]
        public string? send (string mail_from, string[] recipients,
                             string message, size_t message_len);
    }
}
