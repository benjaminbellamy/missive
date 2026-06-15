// SPDX-License-Identifier: GPL-3.0-or-later

namespace Missive {
    // Converts between a GtkTextBuffer (with our formatting tags) and the
    // constrained HTML subset: <p> <br> <strong> <em> <u> <a href> <ul> <ol>
    // <li>. The output is well-formed XHTML so it can be parsed back reliably
    // by the small tokenizer below — no external HTML parser is needed.
    public class HtmlSerializer : Object {
        public const string TAG_BOLD = "bold";
        public const string TAG_ITALIC = "italic";
        public const string TAG_UNDERLINE = "underline";
        public const string TAG_UL = "ul";
        public const string TAG_OL = "ol";
        // Visual "•"/"1." prefixes shown in the editor; excluded from output.
        public const string TAG_MARKER = "list-marker";

        // --- buffer -> HTML ---------------------------------------------------

        public static string buffer_to_html (
                Gtk.TextBuffer buffer,
                HashTable<unowned Gtk.TextTag, string> links) {
            var sb = new StringBuilder ();
            var table = buffer.get_tag_table ();
            var bold = table.lookup (TAG_BOLD);
            var italic = table.lookup (TAG_ITALIC);
            var underline = table.lookup (TAG_UNDERLINE);
            var ul = table.lookup (TAG_UL);
            var ol = table.lookup (TAG_OL);
            var marker = table.lookup (TAG_MARKER);

            int lines = buffer.get_line_count ();
            string? open_list = null;

            for (int ln = 0; ln < lines; ln++) {
                Gtk.TextIter ls;
                buffer.get_iter_at_line (out ls, ln);
                Gtk.TextIter le = ls;
                if (!le.ends_line ()) {
                    le.forward_to_line_end ();
                }

                bool empty = ls.get_offset () == le.get_offset ();
                // Drop a single trailing empty line so we don't emit <p></p>.
                if (ln == lines - 1 && empty) {
                    break;
                }

                string? list_type = null;
                if (ul != null && ls.has_tag (ul)) {
                    list_type = "ul";
                } else if (ol != null && ls.has_tag (ol)) {
                    list_type = "ol";
                }

                if (list_type != null) {
                    if (open_list != list_type) {
                        if (open_list != null) {
                            sb.append ("</%s>\n".printf (open_list));
                        }
                        sb.append ("<%s>\n".printf (list_type));
                        open_list = list_type;
                    }
                    sb.append ("<li>");
                    append_inline (sb, ls, le, bold, italic, underline, marker, links);
                    sb.append ("</li>\n");
                } else {
                    if (open_list != null) {
                        sb.append ("</%s>\n".printf (open_list));
                        open_list = null;
                    }
                    sb.append ("<p>");
                    append_inline (sb, ls, le, bold, italic, underline, marker, links);
                    sb.append ("</p>\n");
                }
            }

            if (open_list != null) {
                sb.append ("</%s>\n".printf (open_list));
            }
            return sb.str;
        }

        private static void append_inline (
                StringBuilder sb,
                Gtk.TextIter start, Gtk.TextIter end,
                Gtk.TextTag? bold, Gtk.TextTag? italic, Gtk.TextTag? underline,
                Gtk.TextTag? marker,
                HashTable<unowned Gtk.TextTag, string> links) {
            string[] stack_kind = {};
            string[] stack_href = {};
            Gtk.TextIter iter = start;

            while (iter.compare (end) < 0) {
                Gtk.TextIter run_end = iter;
                if (!run_end.forward_to_tag_toggle (null) || run_end.compare (end) > 0) {
                    run_end = end;
                }
                if (run_end.compare (iter) <= 0) {
                    run_end = end;
                }

                // Skip the editor-only list marker prefix.
                if (marker != null && iter.has_tag (marker)) {
                    iter = run_end;
                    continue;
                }

                bool b = bold != null && iter.has_tag (bold);
                bool i = italic != null && iter.has_tag (italic);
                bool u = underline != null && iter.has_tag (underline);
                string? href = null;
                foreach (var t in iter.get_tags ()) {
                    if (links.contains (t)) {
                        href = links.lookup (t);
                        break;
                    }
                }

                // Canonical order keeps the open/close stack properly nested.
                string[] want_kind = {};
                string[] want_href = {};
                if (href != null) { want_kind += "a"; want_href += href; }
                if (b) { want_kind += "strong"; want_href += ""; }
                if (i) { want_kind += "em"; want_href += ""; }
                if (u) { want_kind += "u"; want_href += ""; }

                int k = 0;
                while (k < stack_kind.length && k < want_kind.length
                       && stack_kind[k] == want_kind[k]
                       && stack_href[k] == want_href[k]) {
                    k++;
                }
                for (int s = stack_kind.length - 1; s >= k; s--) {
                    sb.append ("</%s>".printf (stack_kind[s]));
                }
                stack_kind = stack_kind[0:k];
                stack_href = stack_href[0:k];
                for (int o = k; o < want_kind.length; o++) {
                    if (want_kind[o] == "a") {
                        sb.append ("<a href=\"%s\">".printf (escape_attr (want_href[o])));
                    } else {
                        sb.append ("<%s>".printf (want_kind[o]));
                    }
                    stack_kind += want_kind[o];
                    stack_href += want_href[o];
                }

                sb.append (escape_text (iter.get_text (run_end)));
                iter = run_end;
            }

            for (int s = stack_kind.length - 1; s >= 0; s--) {
                sb.append ("</%s>".printf (stack_kind[s]));
            }
        }

        // --- HTML -> buffer ---------------------------------------------------

        public static void html_to_buffer (
                string html, Gtk.TextBuffer buffer,
                HashTable<unowned Gtk.TextTag, string> links) {
            buffer.set_text ("", 0);
            links.remove_all ();

            var table = buffer.get_tag_table ();
            var bold = table.lookup (TAG_BOLD);
            var italic = table.lookup (TAG_ITALIC);
            var underline = table.lookup (TAG_UNDERLINE);
            var ul = table.lookup (TAG_UL);
            var ol = table.lookup (TAG_OL);

            int bold_depth = 0, italic_depth = 0, underline_depth = 0;
            Gtk.TextTag? link_tag = null;
            string? list_type = null;
            bool first_block = true;
            bool in_block = false;
            int block_start = 0;
            string? block_list = null;

            var tokens = tokenize (html);
            foreach (var tok in tokens) {
                if (tok.kind == TokenKind.OPEN) {
                    switch (tok.name) {
                        case "p":
                            block_list = null;
                            first_block = start_block (buffer, first_block, out block_start);
                            in_block = true;
                            break;
                        case "li":
                            block_list = list_type;
                            first_block = start_block (buffer, first_block, out block_start);
                            in_block = true;
                            break;
                        case "ul": list_type = "ul"; break;
                        case "ol": list_type = "ol"; break;
                        case "strong": case "b": bold_depth++; break;
                        case "em": case "i": italic_depth++; break;
                        case "u": underline_depth++; break;
                        case "a":
                            link_tag = buffer.create_tag (null,
                                "foreground", "#1c71d8",
                                "underline", Pango.Underline.SINGLE);
                            links.insert (link_tag, tok.href);
                            break;
                        case "br":
                            insert_text (buffer, soft_break (),
                                         bold_depth, italic_depth, underline_depth,
                                         link_tag, bold, italic, underline);
                            break;
                        default: break;
                    }
                } else if (tok.kind == TokenKind.CLOSE) {
                    switch (tok.name) {
                        case "p":
                        case "li":
                            apply_block_list (buffer, block_list, block_start, ul, ol);
                            in_block = false;
                            break;
                        case "ul":
                        case "ol": list_type = null; break;
                        case "strong": case "b":
                            if (bold_depth > 0) bold_depth--;
                            break;
                        case "em": case "i":
                            if (italic_depth > 0) italic_depth--;
                            break;
                        case "u":
                            if (underline_depth > 0) underline_depth--;
                            break;
                        case "a": link_tag = null; break;
                        default: break;
                    }
                } else if (in_block) {
                    insert_text (buffer, tok.text,
                                 bold_depth, italic_depth, underline_depth,
                                 link_tag,
                                 bold, italic, underline);
                }
            }
        }

        private static bool start_block (Gtk.TextBuffer buffer, bool first,
                                         out int block_start) {
            if (!first) {
                Gtk.TextIter end;
                buffer.get_end_iter (out end);
                buffer.insert (ref end, "\n", -1);
            }
            Gtk.TextIter end2;
            buffer.get_end_iter (out end2);
            block_start = end2.get_offset ();
            return false;
        }

        private static void apply_block_list (Gtk.TextBuffer buffer, string? list,
                                              int block_start,
                                              Gtk.TextTag? ul, Gtk.TextTag? ol) {
            if (list == null) {
                return;
            }
            var tag = list == "ul" ? ul : ol;
            if (tag == null) {
                return;
            }
            Gtk.TextIter s, e;
            buffer.get_iter_at_offset (out s, block_start);
            buffer.get_end_iter (out e);
            buffer.apply_tag (tag, s, e);
        }

        private static void insert_text (
                Gtk.TextBuffer buffer, string text,
                int bold_depth, int italic_depth, int underline_depth,
                Gtk.TextTag? link_tag,
                Gtk.TextTag? bold, Gtk.TextTag? italic, Gtk.TextTag? underline) {
            if (text == "") {
                return;
            }
            Gtk.TextIter end;
            buffer.get_end_iter (out end);
            int start_offset = end.get_offset ();
            buffer.insert (ref end, text, -1);

            Gtk.TextIter s, e;
            buffer.get_iter_at_offset (out s, start_offset);
            buffer.get_end_iter (out e);
            if (bold_depth > 0 && bold != null) buffer.apply_tag (bold, s, e);
            if (italic_depth > 0 && italic != null) buffer.apply_tag (italic, s, e);
            if (underline_depth > 0 && underline != null) buffer.apply_tag (underline, s, e);
            if (link_tag != null) buffer.apply_tag (link_tag, s, e);
        }

        // --- HTML -> plain text ----------------------------------------------

        // Deterministic plain-text rendition for the text/plain part: tags are
        // stripped, <li> become lines, <br> a newline, <p> a blank line, and a
        // link's target is kept in parentheses after its text.
        public static string html_to_plain (string html) {
            var sb = new StringBuilder ();
            string? href = null;

            foreach (var tok in tokenize (html)) {
                if (tok.kind == TokenKind.OPEN) {
                    switch (tok.name) {
                        case "br": sb.append_c ('\n'); break;
                        case "li": sb.append ("- "); break;
                        case "a": href = tok.href; break;
                        default: break;
                    }
                } else if (tok.kind == TokenKind.CLOSE) {
                    switch (tok.name) {
                        case "p": sb.append ("\n\n"); break;
                        case "li": sb.append_c ('\n'); break;
                        case "a":
                            if (href != null && href != "") {
                                sb.append (" (");
                                sb.append (href);
                                sb.append (")");
                            }
                            href = null;
                            break;
                        default: break;
                    }
                } else {
                    sb.append (tok.text);
                }
            }

            var text = sb.str;
            while (text.contains ("\n\n\n")) {
                text = text.replace ("\n\n\n", "\n\n");
            }
            return text.strip ();
        }

        // --- tiny XHTML tokenizer --------------------------------------------

        private enum TokenKind { OPEN, CLOSE, TEXT }

        private class Token {
            public TokenKind kind;
            public string name;
            public string href;
            public string text;
        }

        private static Token[] tokenize (string html) {
            Token[] tokens = {};
            int i = 0;
            int n = html.length;
            while (i < n) {
                if (html[i] == '<') {
                    int j = html.index_of_char ('>', i);
                    if (j < 0) {
                        break;
                    }
                    string raw = html.substring (i + 1, j - i - 1).strip ();
                    i = j + 1;
                    if (raw == "") {
                        continue;
                    }
                    bool closing = raw.has_prefix ("/");
                    if (closing) {
                        raw = raw.substring (1).strip ();
                    }
                    bool self_close = raw.has_suffix ("/");
                    if (self_close) {
                        raw = raw.substring (0, raw.length - 1).strip ();
                    }
                    string name = raw;
                    int sp = raw.index_of_char (' ');
                    if (sp >= 0) {
                        name = raw.substring (0, sp);
                    }
                    name = name.down ();

                    var tok = new Token ();
                    tok.name = name;
                    if (closing) {
                        tok.kind = TokenKind.CLOSE;
                    } else {
                        tok.kind = TokenKind.OPEN;
                        if (name == "a") {
                            tok.href = extract_href (raw);
                        }
                        // Self-closing tags (e.g. <br/>) carry no closing token;
                        // they are handled inline when consumed.
                        tokens += tok;
                        continue;
                    }
                    tokens += tok;
                } else {
                    int k = html.index_of_char ('<', i);
                    if (k < 0) {
                        k = n;
                    }
                    var tok = new Token ();
                    tok.kind = TokenKind.TEXT;
                    tok.text = unescape (html.substring (i, k - i));
                    tokens += tok;
                    i = k;
                }
            }
            return tokens;
        }

        private static string extract_href (string raw) {
            int h = raw.index_of ("href");
            if (h < 0) {
                return "";
            }
            int q = raw.index_of_char ('"', h);
            if (q < 0) {
                return "";
            }
            int q2 = raw.index_of_char ('"', q + 1);
            if (q2 < 0) {
                return "";
            }
            return unescape (raw.substring (q + 1, q2 - q - 1));
        }

        // --- escaping ---------------------------------------------------------

        // The soft line break (Shift+Enter): U+2028, rendered by Pango within a
        // single paragraph and serialized as <br/>.
        public static string soft_break () {
            return ((unichar) 0x2028).to_string ();
        }

        private static string escape_basic (string s) {
            return s.replace ("&", "&amp;")
                    .replace ("<", "&lt;")
                    .replace (">", "&gt;");
        }

        // Text runs: also turn soft line breaks (U+2028) into <br/>.
        private static string escape_text (string s) {
            return escape_basic (s).replace (" ", "<br/>");
        }

        private static string escape_attr (string s) {
            return escape_basic (s).replace ("\"", "&quot;");
        }

        private static string unescape (string s) {
            return s.replace ("&lt;", "<")
                    .replace ("&gt;", ">")
                    .replace ("&quot;", "\"")
                    .replace ("&apos;", "'")
                    .replace ("&amp;", "&");
        }
    }
}
