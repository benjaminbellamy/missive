// SPDX-License-Identifier: GPL-3.0-or-later

namespace Missive {
    // Stores SMTP passwords in the system keyring via libsecret (the Secret
    // portal). One secret per identity, keyed by identity id. Passwords never
    // touch SQLite, GSettings, logs or disk.
    public class SecretStore : Object {
        private static Secret.Schema? _schema = null;

        private static unowned Secret.Schema schema () {
            if (_schema == null) {
                _schema = new Secret.Schema (
                    "fr.bellamy.missive.SmtpPassword",
                    Secret.SchemaFlags.NONE,
                    "identity_id", Secret.SchemaAttributeType.STRING);
            }
            return _schema;
        }

        // Store (or replace) the password for an identity. Returns true on
        // success; the password itself is never logged.
        public static bool store_password (int64 identity_id, string password) {
            try {
                var label = "Missive SMTP password (identity %s)".printf (
                    identity_id.to_string ());
                return Secret.password_store_sync (
                    schema (), Secret.COLLECTION_DEFAULT, label, password, null,
                    "identity_id", identity_id.to_string ());
            } catch (Error e) {
                warning ("Could not store SMTP password: %s", e.message);
                return false;
            }
        }

        // Look up the password for an identity, or null if none is stored.
        public static string? lookup_password (int64 identity_id) {
            try {
                return Secret.password_lookup_sync (
                    schema (), null, "identity_id", identity_id.to_string ());
            } catch (Error e) {
                warning ("Could not look up SMTP password: %s", e.message);
                return null;
            }
        }

        // Remove the stored password for an identity (e.g. on deletion).
        public static bool clear_password (int64 identity_id) {
            try {
                return Secret.password_clear_sync (
                    schema (), null, "identity_id", identity_id.to_string ());
            } catch (Error e) {
                warning ("Could not clear SMTP password: %s", e.message);
                return false;
            }
        }
    }
}
