// SPDX-License-Identifier: GPL-3.0-or-later

namespace Missive {
    // Runs a campaign off the main thread: sends each pending recipient in idx
    // order over one reused SMTP connection, persisting status after every
    // message so a crash or quit resumes exactly. One campaign runs at a time.
    public class CampaignEngine : Object {
        // A recipient's status changed (rebuild just that row).
        public signal void recipient_changed (int64 campaign_id, int64 recipient_id);
        // Overall progress/status changed.
        public signal void progress (int64 campaign_id);
        // The run ended; message is a human-readable summary or error.
        public signal void finished (int64 campaign_id, string message);

        private string db_path;
        private bool running = false;
        private bool pause_req = false;
        private bool stop_req = false;

        public CampaignEngine (string db_path) {
            this.db_path = db_path;
        }

        // Start a run. Returns false if another run is already in progress.
        public bool run (int64 campaign_id) {
            if (running) {
                return false;
            }
            running = true;
            pause_req = false;
            stop_req = false;
            new Thread<void*> ("campaign-engine", () => {
                worker (campaign_id);
                return null;
            });
            return true;
        }

        public void pause () {
            if (running) {
                pause_req = true;
            }
        }

        public void stop () {
            if (running) {
                stop_req = true;
            }
        }

        // --- worker thread ----------------------------------------------------

        private void worker (int64 cid) {
            Database db;
            try {
                db = new Database (db_path);
            } catch (DatabaseError e) {
                finish_run (cid, _("Database error: %s").printf (e.message));
                return;
            }

            Campaign? campaign = null;
            Identity? identity = null;
            try { campaign = db.get_campaign (cid); } catch (DatabaseError e) { }
            if (campaign == null) {
                finish_run (cid, _("The campaign no longer exists."));
                return;
            }
            try { identity = db.get_identity (campaign.identity_id); } catch (DatabaseError e) { }
            if (identity == null) {
                finish_run (cid, _("The campaign's identity no longer exists."));
                return;
            }
            var password = SecretStore.lookup_password (identity.id);
            if (password == null) {
                finish_run (cid, _("No password is stored for the identity."));
                return;
            }

            // Pre-flight: verify the connection/login before changing anything.
            string? terr = MissiveSmtp.test (identity.smtp_host, identity.smtp_port,
                identity.smtp_encryption, identity.smtp_username, password);
            if (terr != null) {
                finish_run (cid, _("Cannot connect: %s").printf (terr));
                return;
            }

            // Mark running.
            try {
                campaign.status = CAMPAIGN_RUNNING;
                if (campaign.started_at == 0) {
                    campaign.started_at = new DateTime.now_utc ().to_unix ();
                }
                db.update_campaign (campaign);
            } catch (DatabaseError e) { }
            emit_progress (cid);

            var session = new MissiveSmtp.Session (identity.smtp_host,
                identity.smtp_port, identity.smtp_encryption,
                identity.smtp_username, password);
            string[] cc = split_addresses (campaign.cc);
            string[] bcc = split_addresses (campaign.bcc);

            CampaignRecipient[] all = {};
            try { all = db.recipients_for_campaign (cid); } catch (DatabaseError e) { }

            bool halted_on_error = false;
            foreach (var r in all) {
                if (r.status != RECIPIENT_PENDING) {
                    continue;
                }
                if (stop_req || pause_req) {
                    break;
                }

                r.status = RECIPIENT_SENDING;
                try { db.update_recipient_status (r); } catch (DatabaseError e) { }
                emit_recipient (cid, r.id);

                var values = JsonUtil.string_to_object (r.row_data_json);
                var unknown = new HashTable<string, bool> (str_hash, str_equal);
                var message = MessageBuilder.compose (identity,
                    campaign.subject_snapshot, campaign.body_html_snapshot,
                    values, r.to_address, cc, unknown);
                var data = SmtpSender.normalize (MessageBuilder.to_mime_string (message));

                string[] envelope = { r.to_address };
                foreach (var a in cc) { envelope += a; }
                foreach (var a in bcc) { envelope += a; }

                string? err = session.send (identity.from_email, envelope,
                                            data, data.length);
                r.attempts = r.attempts + 1;
                r.sent_at = new DateTime.now_utc ().to_unix ();
                if (err == null) {
                    r.status = RECIPIENT_SENT;
                    r.error_text = "";
                } else {
                    r.status = RECIPIENT_FAILED;
                    r.error_text = err;
                }
                try { db.update_recipient_status (r); } catch (DatabaseError e) { }
                emit_recipient (cid, r.id);

                if (err != null && campaign.stop_on_error) {
                    halted_on_error = true;
                    break;
                }

                interruptible_sleep (campaign.delay_seconds);
            }

            session = null; // closes the connection (QUIT)

            RecipientCounts counts = {};
            try { counts = db.count_recipients_by_status (cid); }
            catch (DatabaseError e) { }

            string final_status;
            if (pause_req && !stop_req && !halted_on_error) {
                final_status = CAMPAIGN_PAUSED;
            } else if (counts.pending == 0) {
                final_status = CAMPAIGN_COMPLETED;
            } else {
                final_status = CAMPAIGN_STOPPED;
            }

            try {
                campaign.status = final_status;
                if (final_status == CAMPAIGN_COMPLETED) {
                    campaign.finished_at = new DateTime.now_utc ().to_unix ();
                }
                db.update_campaign (campaign);
            } catch (DatabaseError e) { }

            running = false;
            emit_progress (cid);

            emit_finished (cid, _("Done: %d sent, %d failed, %d skipped").printf (
                counts.sent, counts.failed, counts.skipped));
        }

        // Reset state and report (used for early failures before the run starts).
        private void finish_run (int64 cid, string message) {
            running = false;
            emit_finished (cid, message);
        }

        private void interruptible_sleep (int seconds) {
            if (seconds <= 0) {
                return;
            }
            for (int i = 0; i < seconds * 10; i++) {
                if (stop_req || pause_req) {
                    return;
                }
                Thread.usleep (100000); // 100 ms
            }
        }

        private string[] split_addresses (string s) {
            string[] result = {};
            foreach (var part in s.split_set (",;")) {
                var a = part.strip ();
                if (a != "") {
                    result += a;
                }
            }
            return result;
        }

        // --- main-thread signal marshaling ------------------------------------

        private void emit_progress (int64 cid) {
            Idle.add (() => { progress (cid); return Source.REMOVE; });
        }

        private void emit_recipient (int64 cid, int64 rid) {
            Idle.add (() => { recipient_changed (cid, rid); return Source.REMOVE; });
        }

        private void emit_finished (int64 cid, string message) {
            Idle.add (() => { finished (cid, message); return Source.REMOVE; });
        }
    }
}
