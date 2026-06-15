// SPDX-License-Identifier: GPL-3.0-or-later

namespace Missive {
    public errordomain DatabaseError {
        OPEN,
        PREPARE,
        EXEC
    }

    // SQLite-backed store for every entity. One file under the app data dir
    // holds identities, templates, CSV sheets, campaigns and per-recipient
    // status. The schema is versioned with PRAGMA user_version so future
    // migrations are possible.
    public class Database : Object {
        // Bump this and add an `if (version < N)` block in migrate() to evolve
        // the schema without losing user data.
        public const int SCHEMA_VERSION = 1;

        private Sqlite.Database db;

        public Database (string path) throws DatabaseError {
            int rc = Sqlite.Database.open_v2 (
                path, out db,
                Sqlite.OPEN_READWRITE | Sqlite.OPEN_CREATE, null
            );
            if (rc != Sqlite.OK) {
                throw new DatabaseError.OPEN (
                    "Cannot open database '%s': %s".printf (
                        path, db != null ? db.errmsg () : "unknown error"));
            }
            exec ("PRAGMA foreign_keys = ON;");
            exec ("PRAGMA journal_mode = WAL;");
            // The engine (worker thread) and the UI (main thread) each open a
            // connection; retry instead of failing on a momentary writer lock.
            exec ("PRAGMA busy_timeout = 5000;");
            migrate ();
        }

        // --- low-level helpers ------------------------------------------------

        private void exec (string sql) throws DatabaseError {
            string errmsg;
            int rc = db.exec (sql, null, out errmsg);
            if (rc != Sqlite.OK) {
                throw new DatabaseError.EXEC ("SQL error: %s".printf (errmsg));
            }
        }

        private Sqlite.Statement prepare (string sql) throws DatabaseError {
            Sqlite.Statement stmt;
            int rc = db.prepare_v2 (sql, sql.length, out stmt);
            if (rc != Sqlite.OK) {
                throw new DatabaseError.PREPARE (
                    "Failed to prepare statement: %s".printf (db.errmsg ()));
            }
            return stmt;
        }

        private void run (Sqlite.Statement stmt, string what) throws DatabaseError {
            if (stmt.step () != Sqlite.DONE) {
                throw new DatabaseError.EXEC (
                    "%s failed: %s".printf (what, db.errmsg ()));
            }
        }

        // --- migrations -------------------------------------------------------

        private int get_user_version () throws DatabaseError {
            var stmt = prepare ("PRAGMA user_version;");
            return stmt.step () == Sqlite.ROW ? stmt.column_int (0) : 0;
        }

        private void migrate () throws DatabaseError {
            int version = get_user_version ();
            if (version < 1) {
                exec (SCHEMA_V1);
                version = 1;
            }
            // Future: if (version < 2) { exec (SCHEMA_V2); version = 2; }
            exec ("PRAGMA user_version = %d;".printf (SCHEMA_VERSION));
        }

        private const string SCHEMA_V1 = """
            CREATE TABLE IF NOT EXISTS identity (
                id              INTEGER PRIMARY KEY AUTOINCREMENT,
                name            TEXT NOT NULL DEFAULT '',
                from_name       TEXT NOT NULL DEFAULT '',
                from_email      TEXT NOT NULL DEFAULT '',
                smtp_host       TEXT NOT NULL DEFAULT '',
                smtp_port       INTEGER NOT NULL DEFAULT 465,
                smtp_encryption TEXT NOT NULL DEFAULT 'smtps',
                smtp_username   TEXT NOT NULL DEFAULT '',
                signature_html  TEXT NOT NULL DEFAULT ''
            );

            CREATE TABLE IF NOT EXISTS template (
                id         INTEGER PRIMARY KEY AUTOINCREMENT,
                name       TEXT NOT NULL DEFAULT '',
                subject    TEXT NOT NULL DEFAULT '',
                body_html  TEXT NOT NULL DEFAULT '',
                created_at INTEGER NOT NULL DEFAULT 0,
                updated_at INTEGER NOT NULL DEFAULT 0
            );

            CREATE TABLE IF NOT EXISTS csv_sheet (
                id                       INTEGER PRIMARY KEY AUTOINCREMENT,
                name                     TEXT NOT NULL DEFAULT '',
                source_filename          TEXT NOT NULL DEFAULT '',
                columns_json             TEXT NOT NULL DEFAULT '[]',
                row_count                INTEGER NOT NULL DEFAULT 0,
                default_recipient_column TEXT NOT NULL DEFAULT '',
                imported_at              INTEGER NOT NULL DEFAULT 0
            );

            CREATE TABLE IF NOT EXISTS csv_row (
                id        INTEGER PRIMARY KEY AUTOINCREMENT,
                sheet_id  INTEGER NOT NULL REFERENCES csv_sheet(id) ON DELETE CASCADE,
                idx       INTEGER NOT NULL DEFAULT 0,
                data_json TEXT NOT NULL DEFAULT '{}'
            );
            CREATE INDEX IF NOT EXISTS idx_csv_row_sheet ON csv_row(sheet_id, idx);

            CREATE TABLE IF NOT EXISTS campaign (
                id                 INTEGER PRIMARY KEY AUTOINCREMENT,
                name               TEXT NOT NULL DEFAULT '',
                status             TEXT NOT NULL DEFAULT 'draft',
                identity_id        INTEGER NOT NULL DEFAULT 0,
                csv_sheet_id       INTEGER NOT NULL DEFAULT 0,
                recipient_column   TEXT NOT NULL DEFAULT '',
                cc                 TEXT NOT NULL DEFAULT '',
                bcc                TEXT NOT NULL DEFAULT '',
                subject_snapshot   TEXT NOT NULL DEFAULT '',
                body_html_snapshot TEXT NOT NULL DEFAULT '',
                delay_seconds      INTEGER NOT NULL DEFAULT 5,
                stop_on_error      INTEGER NOT NULL DEFAULT 0,
                created_at         INTEGER NOT NULL DEFAULT 0,
                started_at         INTEGER NOT NULL DEFAULT 0,
                finished_at        INTEGER NOT NULL DEFAULT 0
            );

            CREATE TABLE IF NOT EXISTS campaign_recipient (
                id            INTEGER PRIMARY KEY AUTOINCREMENT,
                campaign_id   INTEGER NOT NULL REFERENCES campaign(id) ON DELETE CASCADE,
                idx           INTEGER NOT NULL DEFAULT 0,
                to_address    TEXT NOT NULL DEFAULT '',
                row_data_json TEXT NOT NULL DEFAULT '{}',
                status        TEXT NOT NULL DEFAULT 'pending',
                error_text    TEXT NOT NULL DEFAULT '',
                attempts      INTEGER NOT NULL DEFAULT 0,
                sent_at       INTEGER NOT NULL DEFAULT 0
            );
            CREATE INDEX IF NOT EXISTS idx_recipient_campaign
                ON campaign_recipient(campaign_id, idx);
        """;

        // --- identity ---------------------------------------------------------

        public int64 insert_identity (Identity it) throws DatabaseError {
            var stmt = prepare ("""
                INSERT INTO identity
                    (name, from_name, from_email, smtp_host, smtp_port,
                     smtp_encryption, smtp_username, signature_html)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?);
            """);
            stmt.bind_text (1, it.name);
            stmt.bind_text (2, it.from_name);
            stmt.bind_text (3, it.from_email);
            stmt.bind_text (4, it.smtp_host);
            stmt.bind_int (5, it.smtp_port);
            stmt.bind_text (6, it.smtp_encryption);
            stmt.bind_text (7, it.smtp_username);
            stmt.bind_text (8, it.signature_html);
            run (stmt, "Insert identity");
            it.id = db.last_insert_rowid ();
            return it.id;
        }

        public void update_identity (Identity it) throws DatabaseError {
            var stmt = prepare ("""
                UPDATE identity SET
                    name = ?, from_name = ?, from_email = ?, smtp_host = ?,
                    smtp_port = ?, smtp_encryption = ?, smtp_username = ?,
                    signature_html = ?
                WHERE id = ?;
            """);
            stmt.bind_text (1, it.name);
            stmt.bind_text (2, it.from_name);
            stmt.bind_text (3, it.from_email);
            stmt.bind_text (4, it.smtp_host);
            stmt.bind_int (5, it.smtp_port);
            stmt.bind_text (6, it.smtp_encryption);
            stmt.bind_text (7, it.smtp_username);
            stmt.bind_text (8, it.signature_html);
            stmt.bind_int64 (9, it.id);
            run (stmt, "Update identity");
        }

        public void delete_identity (int64 id) throws DatabaseError {
            var stmt = prepare ("DELETE FROM identity WHERE id = ?;");
            stmt.bind_int64 (1, id);
            run (stmt, "Delete identity");
        }

        public Identity? get_identity (int64 id) throws DatabaseError {
            var stmt = prepare ("""
                SELECT id, name, from_name, from_email, smtp_host, smtp_port,
                       smtp_encryption, smtp_username, signature_html
                FROM identity WHERE id = ?;
            """);
            stmt.bind_int64 (1, id);
            return stmt.step () == Sqlite.ROW ? row_to_identity (stmt) : null;
        }

        public Identity[] all_identities () throws DatabaseError {
            var stmt = prepare ("""
                SELECT id, name, from_name, from_email, smtp_host, smtp_port,
                       smtp_encryption, smtp_username, signature_html
                FROM identity ORDER BY name COLLATE NOCASE;
            """);
            Identity[] result = {};
            while (stmt.step () == Sqlite.ROW) {
                result += row_to_identity (stmt);
            }
            return result;
        }

        private Identity row_to_identity (Sqlite.Statement s) {
            var it = new Identity ();
            it.id = s.column_int64 (0);
            it.name = s.column_text (1) ?? "";
            it.from_name = s.column_text (2) ?? "";
            it.from_email = s.column_text (3) ?? "";
            it.smtp_host = s.column_text (4) ?? "";
            it.smtp_port = s.column_int (5);
            it.smtp_encryption = s.column_text (6) ?? ENCRYPTION_SMTPS;
            it.smtp_username = s.column_text (7) ?? "";
            it.signature_html = s.column_text (8) ?? "";
            return it;
        }

        // --- template ---------------------------------------------------------

        public int64 insert_template (Template t) throws DatabaseError {
            var stmt = prepare ("""
                INSERT INTO template (name, subject, body_html, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?);
            """);
            stmt.bind_text (1, t.name);
            stmt.bind_text (2, t.subject);
            stmt.bind_text (3, t.body_html);
            stmt.bind_int64 (4, t.created_at);
            stmt.bind_int64 (5, t.updated_at);
            run (stmt, "Insert template");
            t.id = db.last_insert_rowid ();
            return t.id;
        }

        public void update_template (Template t) throws DatabaseError {
            var stmt = prepare ("""
                UPDATE template SET name = ?, subject = ?, body_html = ?,
                    updated_at = ? WHERE id = ?;
            """);
            stmt.bind_text (1, t.name);
            stmt.bind_text (2, t.subject);
            stmt.bind_text (3, t.body_html);
            stmt.bind_int64 (4, t.updated_at);
            stmt.bind_int64 (5, t.id);
            run (stmt, "Update template");
        }

        public void delete_template (int64 id) throws DatabaseError {
            var stmt = prepare ("DELETE FROM template WHERE id = ?;");
            stmt.bind_int64 (1, id);
            run (stmt, "Delete template");
        }

        public Template? get_template (int64 id) throws DatabaseError {
            var stmt = prepare ("""
                SELECT id, name, subject, body_html, created_at, updated_at
                FROM template WHERE id = ?;
            """);
            stmt.bind_int64 (1, id);
            return stmt.step () == Sqlite.ROW ? row_to_template (stmt) : null;
        }

        public Template[] all_templates () throws DatabaseError {
            var stmt = prepare ("""
                SELECT id, name, subject, body_html, created_at, updated_at
                FROM template ORDER BY name COLLATE NOCASE;
            """);
            Template[] result = {};
            while (stmt.step () == Sqlite.ROW) {
                result += row_to_template (stmt);
            }
            return result;
        }

        private Template row_to_template (Sqlite.Statement s) {
            var t = new Template ();
            t.id = s.column_int64 (0);
            t.name = s.column_text (1) ?? "";
            t.subject = s.column_text (2) ?? "";
            t.body_html = s.column_text (3) ?? "";
            t.created_at = s.column_int64 (4);
            t.updated_at = s.column_int64 (5);
            return t;
        }

        // --- csv sheet & rows -------------------------------------------------

        public int64 insert_sheet (CsvSheet sh) throws DatabaseError {
            var stmt = prepare ("""
                INSERT INTO csv_sheet
                    (name, source_filename, columns_json, row_count,
                     default_recipient_column, imported_at)
                VALUES (?, ?, ?, ?, ?, ?);
            """);
            stmt.bind_text (1, sh.name);
            stmt.bind_text (2, sh.source_filename);
            stmt.bind_text (3, sh.columns_json);
            stmt.bind_int (4, sh.row_count);
            stmt.bind_text (5, sh.default_recipient_column);
            stmt.bind_int64 (6, sh.imported_at);
            run (stmt, "Insert sheet");
            sh.id = db.last_insert_rowid ();
            return sh.id;
        }

        public void update_sheet (CsvSheet sh) throws DatabaseError {
            var stmt = prepare ("""
                UPDATE csv_sheet SET name = ?, default_recipient_column = ?
                WHERE id = ?;
            """);
            stmt.bind_text (1, sh.name);
            stmt.bind_text (2, sh.default_recipient_column);
            stmt.bind_int64 (3, sh.id);
            run (stmt, "Update sheet");
        }

        public void delete_sheet (int64 id) throws DatabaseError {
            var stmt = prepare ("DELETE FROM csv_sheet WHERE id = ?;");
            stmt.bind_int64 (1, id);
            run (stmt, "Delete sheet");
        }

        public CsvSheet? get_sheet (int64 id) throws DatabaseError {
            var stmt = prepare ("""
                SELECT id, name, source_filename, columns_json, row_count,
                       default_recipient_column, imported_at
                FROM csv_sheet WHERE id = ?;
            """);
            stmt.bind_int64 (1, id);
            return stmt.step () == Sqlite.ROW ? row_to_sheet (stmt) : null;
        }

        public CsvSheet[] all_sheets () throws DatabaseError {
            var stmt = prepare ("""
                SELECT id, name, source_filename, columns_json, row_count,
                       default_recipient_column, imported_at
                FROM csv_sheet ORDER BY name COLLATE NOCASE;
            """);
            CsvSheet[] result = {};
            while (stmt.step () == Sqlite.ROW) {
                result += row_to_sheet (stmt);
            }
            return result;
        }

        private CsvSheet row_to_sheet (Sqlite.Statement s) {
            var sh = new CsvSheet ();
            sh.id = s.column_int64 (0);
            sh.name = s.column_text (1) ?? "";
            sh.source_filename = s.column_text (2) ?? "";
            sh.columns_json = s.column_text (3) ?? "[]";
            sh.row_count = s.column_int (4);
            sh.default_recipient_column = s.column_text (5) ?? "";
            sh.imported_at = s.column_int64 (6);
            return sh;
        }

        // Bulk-insert rows for a sheet inside one transaction.
        public void insert_rows (int64 sheet_id, CsvRow[] rows) throws DatabaseError {
            exec ("BEGIN TRANSACTION;");
            try {
                var stmt = prepare ("""
                    INSERT INTO csv_row (sheet_id, idx, data_json)
                    VALUES (?, ?, ?);
                """);
                foreach (var r in rows) {
                    stmt.reset ();
                    stmt.bind_int64 (1, sheet_id);
                    stmt.bind_int (2, r.idx);
                    stmt.bind_text (3, r.data_json);
                    run (stmt, "Insert row");
                }
                exec ("COMMIT;");
            } catch (DatabaseError e) {
                exec ("ROLLBACK;");
                throw e;
            }
        }

        public CsvRow[] rows_for_sheet (int64 sheet_id) throws DatabaseError {
            var stmt = prepare ("""
                SELECT id, sheet_id, idx, data_json
                FROM csv_row WHERE sheet_id = ? ORDER BY idx;
            """);
            stmt.bind_int64 (1, sheet_id);
            CsvRow[] result = {};
            while (stmt.step () == Sqlite.ROW) {
                var r = new CsvRow ();
                r.id = stmt.column_int64 (0);
                r.sheet_id = stmt.column_int64 (1);
                r.idx = stmt.column_int (2);
                r.data_json = stmt.column_text (3) ?? "{}";
                result += r;
            }
            return result;
        }

        // --- campaign & recipients -------------------------------------------

        public int64 insert_campaign (Campaign c) throws DatabaseError {
            var stmt = prepare ("""
                INSERT INTO campaign
                    (name, status, identity_id, csv_sheet_id, recipient_column,
                     cc, bcc, subject_snapshot, body_html_snapshot,
                     delay_seconds, stop_on_error, created_at, started_at,
                     finished_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """);
            stmt.bind_text (1, c.name);
            stmt.bind_text (2, c.status);
            stmt.bind_int64 (3, c.identity_id);
            stmt.bind_int64 (4, c.csv_sheet_id);
            stmt.bind_text (5, c.recipient_column);
            stmt.bind_text (6, c.cc);
            stmt.bind_text (7, c.bcc);
            stmt.bind_text (8, c.subject_snapshot);
            stmt.bind_text (9, c.body_html_snapshot);
            stmt.bind_int (10, c.delay_seconds);
            stmt.bind_int (11, c.stop_on_error ? 1 : 0);
            stmt.bind_int64 (12, c.created_at);
            stmt.bind_int64 (13, c.started_at);
            stmt.bind_int64 (14, c.finished_at);
            run (stmt, "Insert campaign");
            c.id = db.last_insert_rowid ();
            return c.id;
        }

        public void update_campaign (Campaign c) throws DatabaseError {
            var stmt = prepare ("""
                UPDATE campaign SET
                    name = ?, status = ?, identity_id = ?, recipient_column = ?,
                    cc = ?, bcc = ?, delay_seconds = ?, stop_on_error = ?,
                    started_at = ?, finished_at = ?
                WHERE id = ?;
            """);
            stmt.bind_text (1, c.name);
            stmt.bind_text (2, c.status);
            stmt.bind_int64 (3, c.identity_id);
            stmt.bind_text (4, c.recipient_column);
            stmt.bind_text (5, c.cc);
            stmt.bind_text (6, c.bcc);
            stmt.bind_int (7, c.delay_seconds);
            stmt.bind_int (8, c.stop_on_error ? 1 : 0);
            stmt.bind_int64 (9, c.started_at);
            stmt.bind_int64 (10, c.finished_at);
            stmt.bind_int64 (11, c.id);
            run (stmt, "Update campaign");
        }

        public void set_campaign_status (int64 id, string status) throws DatabaseError {
            var stmt = prepare ("UPDATE campaign SET status = ? WHERE id = ?;");
            stmt.bind_text (1, status);
            stmt.bind_int64 (2, id);
            run (stmt, "Set campaign status");
        }

        public void delete_campaign (int64 id) throws DatabaseError {
            var stmt = prepare ("DELETE FROM campaign WHERE id = ?;");
            stmt.bind_int64 (1, id);
            run (stmt, "Delete campaign");
        }

        public Campaign? get_campaign (int64 id) throws DatabaseError {
            var stmt = prepare (CAMPAIGN_SELECT + " WHERE id = ?;");
            stmt.bind_int64 (1, id);
            return stmt.step () == Sqlite.ROW ? row_to_campaign (stmt) : null;
        }

        public Campaign[] all_campaigns () throws DatabaseError {
            var stmt = prepare (CAMPAIGN_SELECT + " ORDER BY created_at DESC;");
            Campaign[] result = {};
            while (stmt.step () == Sqlite.ROW) {
                result += row_to_campaign (stmt);
            }
            return result;
        }

        private const string CAMPAIGN_SELECT = """
            SELECT id, name, status, identity_id, csv_sheet_id, recipient_column,
                   cc, bcc, subject_snapshot, body_html_snapshot, delay_seconds,
                   stop_on_error, created_at, started_at, finished_at
            FROM campaign""";

        private Campaign row_to_campaign (Sqlite.Statement s) {
            var c = new Campaign ();
            c.id = s.column_int64 (0);
            c.name = s.column_text (1) ?? "";
            c.status = s.column_text (2) ?? CAMPAIGN_DRAFT;
            c.identity_id = s.column_int64 (3);
            c.csv_sheet_id = s.column_int64 (4);
            c.recipient_column = s.column_text (5) ?? "";
            c.cc = s.column_text (6) ?? "";
            c.bcc = s.column_text (7) ?? "";
            c.subject_snapshot = s.column_text (8) ?? "";
            c.body_html_snapshot = s.column_text (9) ?? "";
            c.delay_seconds = s.column_int (10);
            c.stop_on_error = s.column_int (11) != 0;
            c.created_at = s.column_int64 (12);
            c.started_at = s.column_int64 (13);
            c.finished_at = s.column_int64 (14);
            return c;
        }

        // Bulk-insert recipients for a campaign inside one transaction.
        public void insert_recipients (int64 campaign_id, CampaignRecipient[] recipients)
                throws DatabaseError {
            exec ("BEGIN TRANSACTION;");
            try {
                var stmt = prepare ("""
                    INSERT INTO campaign_recipient
                        (campaign_id, idx, to_address, row_data_json, status,
                         error_text, attempts, sent_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?);
                """);
                foreach (var r in recipients) {
                    stmt.reset ();
                    stmt.bind_int64 (1, campaign_id);
                    stmt.bind_int (2, r.idx);
                    stmt.bind_text (3, r.to_address);
                    stmt.bind_text (4, r.row_data_json);
                    stmt.bind_text (5, r.status);
                    stmt.bind_text (6, r.error_text);
                    stmt.bind_int (7, r.attempts);
                    stmt.bind_int64 (8, r.sent_at);
                    run (stmt, "Insert recipient");
                }
                exec ("COMMIT;");
            } catch (DatabaseError e) {
                exec ("ROLLBACK;");
                throw e;
            }
        }

        public CampaignRecipient[] recipients_for_campaign (int64 campaign_id)
                throws DatabaseError {
            var stmt = prepare ("""
                SELECT id, campaign_id, idx, to_address, row_data_json, status,
                       error_text, attempts, sent_at
                FROM campaign_recipient WHERE campaign_id = ? ORDER BY idx;
            """);
            stmt.bind_int64 (1, campaign_id);
            CampaignRecipient[] result = {};
            while (stmt.step () == Sqlite.ROW) {
                result += row_to_recipient (stmt);
            }
            return result;
        }

        public CampaignRecipient? get_recipient (int64 id) throws DatabaseError {
            var stmt = prepare ("""
                SELECT id, campaign_id, idx, to_address, row_data_json, status,
                       error_text, attempts, sent_at
                FROM campaign_recipient WHERE id = ?;
            """);
            stmt.bind_int64 (1, id);
            return stmt.step () == Sqlite.ROW ? row_to_recipient (stmt) : null;
        }

        private CampaignRecipient row_to_recipient (Sqlite.Statement s) {
            var r = new CampaignRecipient ();
            r.id = s.column_int64 (0);
            r.campaign_id = s.column_int64 (1);
            r.idx = s.column_int (2);
            r.to_address = s.column_text (3) ?? "";
            r.row_data_json = s.column_text (4) ?? "{}";
            r.status = s.column_text (5) ?? RECIPIENT_PENDING;
            r.error_text = s.column_text (6) ?? "";
            r.attempts = s.column_int (7);
            r.sent_at = s.column_int64 (8);
            return r;
        }

        // Persist the outcome of a single recipient. Called after each send so a
        // crash or quit can be resumed exactly.
        public void update_recipient_status (CampaignRecipient r) throws DatabaseError {
            var stmt = prepare ("""
                UPDATE campaign_recipient SET status = ?, error_text = ?,
                    attempts = ?, sent_at = ? WHERE id = ?;
            """);
            stmt.bind_text (1, r.status);
            stmt.bind_text (2, r.error_text);
            stmt.bind_int (3, r.attempts);
            stmt.bind_int64 (4, r.sent_at);
            stmt.bind_int64 (5, r.id);
            run (stmt, "Update recipient");
        }

        // Reset every failed recipient of a campaign back to pending (Retry).
        public void reset_failed_recipients (int64 campaign_id) throws DatabaseError {
            var stmt = prepare ("""
                UPDATE campaign_recipient
                SET status = 'pending', error_text = '' WHERE campaign_id = ? AND status = 'failed';
            """);
            stmt.bind_int64 (1, campaign_id);
            run (stmt, "Reset failed recipients");
        }

        // Count recipients of a campaign in a given status (for progress).
        public int count_recipients (int64 campaign_id, string status) throws DatabaseError {
            var stmt = prepare ("""
                SELECT COUNT(*) FROM campaign_recipient
                WHERE campaign_id = ? AND status = ?;
            """);
            stmt.bind_int64 (1, campaign_id);
            stmt.bind_text (2, status);
            return stmt.step () == Sqlite.ROW ? stmt.column_int (0) : 0;
        }

        // Recover from a crash/quit during a run: a campaign left 'running' is
        // moved to 'paused', and any recipient left 'sending' goes back to
        // 'pending' so Continue resumes exactly where it stopped.
        public void reset_interrupted_runs () throws DatabaseError {
            exec ("UPDATE campaign_recipient SET status = 'pending' WHERE status = 'sending';");
            exec ("UPDATE campaign SET status = 'paused' WHERE status = 'running';");
        }

        // All status counts for a campaign in a single grouped query.
        public RecipientCounts count_recipients_by_status (int64 campaign_id)
                throws DatabaseError {
            var counts = RecipientCounts ();
            var stmt = prepare ("""
                SELECT status, COUNT(*) FROM campaign_recipient
                WHERE campaign_id = ? GROUP BY status;
            """);
            stmt.bind_int64 (1, campaign_id);
            while (stmt.step () == Sqlite.ROW) {
                var status = stmt.column_text (0);
                int n = stmt.column_int (1);
                counts.total += n;
                switch (status) {
                    case RECIPIENT_SENT: counts.sent = n; break;
                    case RECIPIENT_SENDING: counts.sending = n; break;
                    case RECIPIENT_FAILED: counts.failed = n; break;
                    case RECIPIENT_SKIPPED: counts.skipped = n; break;
                    case RECIPIENT_PENDING: counts.pending = n; break;
                    default: break;
                }
            }
            return counts;
        }
    }
}
