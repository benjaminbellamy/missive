// SPDX-License-Identifier: GPL-3.0-or-later

namespace Missive {
    public errordomain CsvError {
        NOT_UTF8,
        NO_HEADER,
        NO_DATA
    }

    // One CSV record: its ordered field values. Wrapping the row in an object
    // avoids Vala's unsupported jagged (string[][]) arrays.
    public class CsvRecord : Object {
        public string[] fields;
    }

    // Parsed CSV: the header row and the data rows below it. Each data row is
    // normalized to the header's column count (missing cells become "", extra
    // cells are dropped).
    public class CsvData : Object {
        public string[] columns;
        public CsvRecord[] rows;
    }

    // RFC 4180 CSV reader: handles quoted fields, embedded commas and newlines,
    // doubled quotes, CRLF/LF/CR line endings, and a leading UTF-8 BOM.
    public class CsvParser : Object {

        public static CsvData parse (string input) throws CsvError {
            if (!input.validate ()) {
                throw new CsvError.NOT_UTF8 ("The file is not valid UTF-8.");
            }

            string text = input;
            if (text.has_prefix ("\xEF\xBB\xBF")) {
                text = text.substring (3);
            }

            CsvRecord[] records = {};
            string[] current = {};
            var field = new StringBuilder ();
            bool in_quotes = false;
            bool row_has_content = false;
            int i = 0;
            int n = text.length;

            // Bytes are scanned one at a time; multibyte UTF-8 sequences are
            // copied through verbatim since delimiters and quotes are all ASCII.
            while (i < n) {
                char c = text[i];

                if (in_quotes) {
                    if (c == '"') {
                        if (i + 1 < n && text[i + 1] == '"') {
                            field.append_c ('"');
                            i += 2;
                        } else {
                            in_quotes = false;
                            i++;
                        }
                    } else {
                        field.append_c (c);
                        i++;
                    }
                    continue;
                }

                if (c == '"') {
                    in_quotes = true;
                    row_has_content = true;
                    i++;
                } else if (c == ',') {
                    current += field.str;
                    field.erase ();
                    row_has_content = true;
                    i++;
                } else if (c == '\n' || c == '\r') {
                    current += field.str;
                    field.erase ();
                    if (row_has_content) {
                        var record = new CsvRecord ();
                        record.fields = current;
                        records += record;
                    }
                    current = {};
                    row_has_content = false;
                    // Treat CRLF as a single line break.
                    if (c == '\r' && i + 1 < n && text[i + 1] == '\n') {
                        i += 2;
                    } else {
                        i++;
                    }
                } else {
                    field.append_c (c);
                    row_has_content = true;
                    i++;
                }
            }

            // Emit a final record when the file does not end with a newline.
            if (row_has_content || field.len > 0) {
                current += field.str;
                var record = new CsvRecord ();
                record.fields = current;
                records += record;
            }

            // Trim surrounding whitespace from every value; drop fully empty rows.
            CsvRecord[] cleaned = {};
            foreach (var record in records) {
                string[] trimmed = {};
                bool any = false;
                foreach (var value in record.fields) {
                    var v = value.strip ();
                    if (v != "") {
                        any = true;
                    }
                    trimmed += v;
                }
                if (any) {
                    var keep = new CsvRecord ();
                    keep.fields = trimmed;
                    cleaned += keep;
                }
            }

            if (cleaned.length == 0) {
                throw new CsvError.NO_HEADER ("The file has no header row.");
            }
            if (cleaned.length < 2) {
                throw new CsvError.NO_DATA ("The file has a header but no data rows.");
            }

            var data = new CsvData ();
            data.columns = cleaned[0].fields;
            int col_count = data.columns.length;

            CsvRecord[] rows = {};
            for (int r = 1; r < cleaned.length; r++) {
                string[] row = {};
                for (int col = 0; col < col_count; col++) {
                    row += col < cleaned[r].fields.length ? cleaned[r].fields[col] : "";
                }
                var rec = new CsvRecord ();
                rec.fields = row;
                rows += rec;
            }
            data.rows = rows;
            return data;
        }
    }
}
