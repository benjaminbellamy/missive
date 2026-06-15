// SPDX-License-Identifier: GPL-3.0-or-later

namespace Missive {
    // An imported CSV sheet. The ordered column names are kept as a JSON array
    // string in columns_json; rows are stored separately as CsvRow records.
    public class CsvSheet : Object {
        public int64 id { get; set; default = 0; }
        public string name { get; set; default = ""; }
        public string source_filename { get; set; default = ""; }
        public string columns_json { get; set; default = "[]"; }
        public int row_count { get; set; default = 0; }
        public string default_recipient_column { get; set; default = ""; }
        public int64 imported_at { get; set; default = 0; }
    }

    // One row of a CSV sheet. data_json is a JSON object mapping column name to
    // value, so a row is self-describing regardless of the original file.
    public class CsvRow : Object {
        public int64 id { get; set; default = 0; }
        public int64 sheet_id { get; set; default = 0; }
        public int idx { get; set; default = 0; }
        public string data_json { get; set; default = "{}"; }
    }
}
