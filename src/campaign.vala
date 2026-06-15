// SPDX-License-Identifier: GPL-3.0-or-later

namespace Missive {
    // Campaign lifecycle states, stored as text in the database.
    public const string CAMPAIGN_DRAFT = "draft";
    public const string CAMPAIGN_RUNNING = "running";
    public const string CAMPAIGN_PAUSED = "paused";
    public const string CAMPAIGN_STOPPED = "stopped";
    public const string CAMPAIGN_COMPLETED = "completed";

    // Per-recipient send states.
    public const string RECIPIENT_PENDING = "pending";
    public const string RECIPIENT_SENDING = "sending";
    public const string RECIPIENT_SENT = "sent";
    public const string RECIPIENT_FAILED = "failed";
    public const string RECIPIENT_SKIPPED = "skipped";

    // Recipient counts for a campaign, grouped by status.
    public struct RecipientCounts {
        public int total;
        public int sent;
        public int sending;
        public int failed;
        public int skipped;
        public int pending;
    }

    // A campaign. The identity is a live reference (resolved at run time); the
    // template subject/body and the CSV rows are snapshotted at creation so
    // later edits to the source template or sheet do not affect the campaign.
    public class Campaign : Object {
        public int64 id { get; set; default = 0; }
        public string name { get; set; default = ""; }
        public string status { get; set; default = CAMPAIGN_DRAFT; }
        public int64 identity_id { get; set; default = 0; }
        public int64 csv_sheet_id { get; set; default = 0; }
        public string recipient_column { get; set; default = ""; }
        public string cc { get; set; default = ""; }
        public string bcc { get; set; default = ""; }
        public string subject_snapshot { get; set; default = ""; }
        public string body_html_snapshot { get; set; default = ""; }
        public int delay_seconds { get; set; default = 5; }
        public bool stop_on_error { get; set; default = false; }
        public int64 created_at { get; set; default = 0; }
        public int64 started_at { get; set; default = 0; }
        public int64 finished_at { get; set; default = 0; }
    }

    // One materialized recipient of a campaign, with a snapshot of its CSV row.
    public class CampaignRecipient : Object {
        public int64 id { get; set; default = 0; }
        public int64 campaign_id { get; set; default = 0; }
        public int idx { get; set; default = 0; }
        public string to_address { get; set; default = ""; }
        public string row_data_json { get; set; default = "{}"; }
        public string status { get; set; default = RECIPIENT_PENDING; }
        public string error_text { get; set; default = ""; }
        public int attempts { get; set; default = 0; }
        public int64 sent_at { get; set; default = 0; }
    }
}
