// SPDX-License-Identifier: GPL-3.0-or-later

namespace Missive {
    // Rich-text template editor: a GtkTextView with a formatting toolbar
    // (bold/italic/underline/link/bullet/numbered) backed by GtkTextTags, plus
    // a live read-only WebKit preview of the serialized HTML. Editing happens in
    // GTK widgets; WebKit only renders the preview.
    [GtkTemplate (ui = "/fr/bellamy/missive/template-editor.ui")]
    public class TemplateEditor : Adw.Dialog {
        [GtkChild] private unowned Adw.EntryRow name_row;
        [GtkChild] private unowned Adw.EntryRow subject_row;
        [GtkChild] private unowned Adw.ComboRow csv_row;
        [GtkChild] private unowned Gtk.FlowBox field_box;
        [GtkChild] private unowned Gtk.TextView body_view;
        [GtkChild] private unowned Gtk.TextView source_view;
        [GtkChild] private unowned Gtk.Box preview_box;
        [GtkChild] private unowned Adw.ViewStack edit_preview_stack;
        [GtkChild] private unowned Gtk.Button cancel_button;
        [GtkChild] private unowned Gtk.Button save_button;
        [GtkChild] private unowned Gtk.ToggleButton bold_button;
        [GtkChild] private unowned Gtk.ToggleButton italic_button;
        [GtkChild] private unowned Gtk.ToggleButton underline_button;
        [GtkChild] private unowned Gtk.Button link_button;
        [GtkChild] private unowned Gtk.Button bullet_button;
        [GtkChild] private unowned Gtk.Button numbered_button;

        public signal void saved ();

        private Database db;
        private Template template;
        private bool is_new;

        private Gtk.TextBuffer buffer;
        private Gtk.TextTag bold_tag;
        private Gtk.TextTag italic_tag;
        private Gtk.TextTag underline_tag;
        private Gtk.TextTag ul_tag;
        private Gtk.TextTag ol_tag;
        private Gtk.TextTag marker_tag;
        private HashTable<unowned Gtk.TextTag, string> links;
        private WebKit.WebView web_view;

        private bool syncing = false;
        private bool pending_bold = false;
        private bool pending_italic = false;
        private bool pending_underline = false;
        private bool updating_markers = false;
        private string current_tab = "edit";

        // Where an inserted {field} token should go (the last text widget used).
        private enum FocusTarget { SUBJECT, BODY, SOURCE }
        private FocusTarget last_focus = FocusTarget.BODY;
        private CsvSheet[] sheets = {};

        public TemplateEditor (Database db, Template? existing) {
            Object ();
            this.db = db;
            this.is_new = existing == null;
            this.template = existing ?? new Template ();

            buffer = body_view.buffer;
            bold_tag = buffer.create_tag (HtmlSerializer.TAG_BOLD,
                "weight", Pango.Weight.BOLD);
            italic_tag = buffer.create_tag (HtmlSerializer.TAG_ITALIC,
                "style", Pango.Style.ITALIC);
            underline_tag = buffer.create_tag (HtmlSerializer.TAG_UNDERLINE,
                "underline", Pango.Underline.SINGLE);
            ul_tag = buffer.create_tag (HtmlSerializer.TAG_UL, "left-margin", 28);
            ol_tag = buffer.create_tag (HtmlSerializer.TAG_OL, "left-margin", 28);
            // Non-editable visual prefix ("• " / "1. ") for list items.
            marker_tag = buffer.create_tag (HtmlSerializer.TAG_MARKER,
                "editable", false, "foreground", "#9a9996");
            links = new HashTable<unowned Gtk.TextTag, string> (direct_hash, direct_equal);

            web_view = new WebKit.WebView () {
                hexpand = true,
                vexpand = true
            };
            preview_box.append (web_view);

            title = is_new ? _("New Template") : _("Edit Template");
            name_row.text = template.name;
            subject_row.text = template.subject;
            if (template.body_html != "") {
                HtmlSerializer.html_to_buffer (template.body_html, buffer, links);
                refresh_list_markers ();
            }

            cancel_button.clicked.connect (() => close ());
            save_button.clicked.connect (on_save);
            bold_button.toggled.connect (on_bold);
            italic_button.toggled.connect (on_italic);
            underline_button.toggled.connect (on_underline);
            link_button.clicked.connect (on_link);
            bullet_button.clicked.connect (() => toggle_list (ul_tag, ol_tag));
            numbered_button.clicked.connect (() => toggle_list (ol_tag, ul_tag));

            buffer.insert_text.connect_after (on_insert_after);
            buffer.notify["cursor-position"].connect (sync_buttons);

            edit_preview_stack.notify["visible-child-name"].connect (on_tab_changed);

            // Shift+Enter inserts a soft line break (<br/>) instead of a new
            // paragraph. CAPTURE phase pre-empts the TextView's default newline.
            var keys = new Gtk.EventControllerKey ();
            keys.set_propagation_phase (Gtk.PropagationPhase.CAPTURE);
            keys.key_pressed.connect ((keyval, keycode, state) => {
                if ((keyval == Gdk.Key.Return || keyval == Gdk.Key.KP_Enter)
                    && (state & Gdk.ModifierType.SHIFT_MASK) != 0) {
                    buffer.delete_selection (false, true);
                    buffer.insert_at_cursor (HtmlSerializer.soft_break (), -1);
                    return true;
                }
                if ((state & Gdk.ModifierType.CONTROL_MASK) != 0) {
                    switch (Gdk.keyval_to_lower (keyval)) {
                        case Gdk.Key.b:
                            bold_button.active = !bold_button.active;
                            return true;
                        case Gdk.Key.i:
                            italic_button.active = !italic_button.active;
                            return true;
                        case Gdk.Key.u:
                            underline_button.active = !underline_button.active;
                            return true;
                        case Gdk.Key.k:
                            on_link ();
                            return true;
                        default:
                            break;
                    }
                }
                return false;
            });
            body_view.add_controller (keys);

            // Remember which text widget was last focused, for token insertion.
            track_focus (subject_row, FocusTarget.SUBJECT);
            track_focus (body_view, FocusTarget.BODY);
            track_focus (source_view, FocusTarget.SOURCE);

            // Populate the CSV field picker.
            try {
                sheets = db.all_sheets ();
            } catch (DatabaseError e) {
                warning ("Could not load sheets: %s", e.message);
            }
            string[] names = { _("None") };
            foreach (var sheet in sheets) {
                names += sheet.name != "" ? sheet.name : _("(unlabeled)");
            }
            csv_row.model = new Gtk.StringList (names);
            csv_row.notify["selected"].connect (on_sheet_selected);
        }

        private void track_focus (Gtk.Widget widget, FocusTarget target) {
            var controller = new Gtk.EventControllerFocus ();
            controller.enter.connect (() => {
                last_focus = target;
            });
            widget.add_controller (controller);
        }

        // --- CSV field picker -------------------------------------------------

        private void on_sheet_selected () {
            Gtk.Widget? child;
            while ((child = field_box.get_first_child ()) != null) {
                field_box.remove (child);
            }

            uint selected = csv_row.selected;
            if (selected == 0 || selected > sheets.length) {
                field_box.visible = false;
                return;
            }

            var columns = JsonUtil.string_to_array (sheets[selected - 1].columns_json);
            if (columns.length == 0) {
                field_box.visible = false;
                return;
            }
            foreach (var column in columns) {
                field_box.append (make_field_button (column));
            }
            field_box.visible = true;
        }

        private Gtk.Button make_field_button (string column) {
            var token = "{" + column + "}";
            // Size each chip exactly to its field name (no truncation).
            var button = new Gtk.Button.with_label (column) {
                tooltip_text = token,
                valign = Gtk.Align.CENTER
            };
            button.add_css_class ("flat");
            button.add_css_class ("field-chip");
            button.clicked.connect (() => insert_token (token));
            return button;
        }

        // Insert a token into whichever field was last edited.
        private void insert_token (string token) {
            switch (last_focus) {
                case FocusTarget.SUBJECT:
                    int pos = subject_row.get_position ();
                    subject_row.insert_text (token, token.length, ref pos);
                    subject_row.set_position (pos);
                    break;
                case FocusTarget.SOURCE:
                    source_view.buffer.insert_at_cursor (token, -1);
                    break;
                default:
                    buffer.insert_at_cursor (token, -1);
                    break;
            }
        }

        // Keep the three views in sync: the rich buffer is canonical; the source
        // tab edits the HTML directly and is committed back on leaving it.
        private void on_tab_changed () {
            var target = edit_preview_stack.visible_child_name;
            if (target == current_tab) {
                return;
            }
            if (current_tab == "source") {
                HtmlSerializer.html_to_buffer (source_view.buffer.text, buffer, links);
                refresh_list_markers ();
            }
            if (target == "source") {
                source_view.buffer.text = HtmlSerializer.buffer_to_html (buffer, links);
            } else if (target == "preview") {
                update_preview ();
            }
            current_tab = target;
        }

        // --- inline formatting ------------------------------------------------

        private void on_bold () {
            if (syncing) {
                return;
            }
            if (buffer.get_has_selection ()) {
                apply_inline (bold_tag, bold_button.active);
            } else {
                pending_bold = bold_button.active;
            }
        }

        private void on_italic () {
            if (syncing) {
                return;
            }
            if (buffer.get_has_selection ()) {
                apply_inline (italic_tag, italic_button.active);
            } else {
                pending_italic = italic_button.active;
            }
        }

        private void on_underline () {
            if (syncing) {
                return;
            }
            if (buffer.get_has_selection ()) {
                apply_inline (underline_tag, underline_button.active);
            } else {
                pending_underline = underline_button.active;
            }
        }

        private void apply_inline (Gtk.TextTag tag, bool active) {
            Gtk.TextIter s, e;
            if (!buffer.get_selection_bounds (out s, out e)) {
                return;
            }
            if (active) {
                buffer.apply_tag (tag, s, e);
            } else {
                buffer.remove_tag (tag, s, e);
            }
        }

        // Apply any pending inline formats to freshly typed text.
        private void on_insert_after (ref Gtk.TextIter pos, string text, int len) {
            if (updating_markers || text.char_count () == 0) {
                return;
            }
            Gtk.TextIter start = pos;
            start.backward_chars (text.char_count ());
            if (pending_bold) buffer.apply_tag (bold_tag, start, pos);
            if (pending_italic) buffer.apply_tag (italic_tag, start, pos);
            if (pending_underline) buffer.apply_tag (underline_tag, start, pos);
        }

        // Reflect the formatting at the cursor / selection start in the toolbar.
        private void sync_buttons () {
            syncing = true;
            Gtk.TextIter a, b;
            bool has = buffer.get_selection_bounds (out a, out b);
            bold_button.active = a.has_tag (bold_tag);
            italic_button.active = a.has_tag (italic_tag);
            underline_button.active = a.has_tag (underline_tag);
            if (!has) {
                pending_bold = bold_button.active;
                pending_italic = italic_button.active;
                pending_underline = underline_button.active;
            }
            syncing = false;
        }

        // --- links ------------------------------------------------------------

        private void on_link () {
            var entry = new Gtk.Entry () {
                placeholder_text = "https://",
                hexpand = true,
                activates_default = true
            };
            var dialog = new Adw.AlertDialog (_("Insert Link"), null);
            dialog.set_extra_child (entry);
            dialog.add_response ("cancel", _("Cancel"));
            dialog.add_response ("insert", _("Insert"));
            dialog.set_response_appearance ("insert", Adw.ResponseAppearance.SUGGESTED);
            dialog.default_response = "insert";
            dialog.close_response = "cancel";
            dialog.response.connect ((response) => {
                if (response != "insert") {
                    return;
                }
                var url = entry.text.strip ();
                if (url != "") {
                    apply_link (url);
                }
            });
            dialog.present (this);
            entry.grab_focus ();
        }

        private void apply_link (string url) {
            var tag = buffer.create_tag (null,
                "foreground", "#1c71d8",
                "underline", Pango.Underline.SINGLE);
            links.insert (tag, url);

            Gtk.TextIter s, e;
            if (buffer.get_selection_bounds (out s, out e)) {
                buffer.apply_tag (tag, s, e);
            } else {
                Gtk.TextIter at;
                buffer.get_iter_at_mark (out at, buffer.get_insert ());
                buffer.insert (ref at, url, -1);
                Gtk.TextIter start = at;
                start.backward_chars (url.char_count ());
                buffer.apply_tag (tag, start, at);
            }
        }

        // --- lists ------------------------------------------------------------

        private void toggle_list (Gtk.TextTag list_tag, Gtk.TextTag other_tag) {
            Gtk.TextIter s, e;
            buffer.get_selection_bounds (out s, out e);
            int first = s.get_line ();
            int last = e.get_line ();

            bool all = true;
            for (int ln = first; ln <= last; ln++) {
                Gtk.TextIter ls;
                buffer.get_iter_at_line (out ls, ln);
                if (!ls.has_tag (list_tag)) {
                    all = false;
                    break;
                }
            }

            for (int ln = first; ln <= last; ln++) {
                Gtk.TextIter ls;
                buffer.get_iter_at_line (out ls, ln);
                Gtk.TextIter le;
                buffer.get_iter_at_line (out le, ln);
                if (!le.forward_line ()) {
                    buffer.get_end_iter (out le);
                }
                buffer.remove_tag (other_tag, ls, le);
                if (all) {
                    buffer.remove_tag (list_tag, ls, le);
                } else {
                    buffer.apply_tag (list_tag, ls, le);
                }
            }
            refresh_list_markers ();
        }

        // Rebuild the visual "• " / "1. " prefixes for list lines. Markers are
        // tagged so the serializer drops them; numbers restart per list block.
        private void refresh_list_markers () {
            updating_markers = true;

            // Strip existing markers.
            for (int ln = 0; ln < buffer.get_line_count (); ln++) {
                Gtk.TextIter ls;
                buffer.get_iter_at_line (out ls, ln);
                Gtk.TextIter me = ls;
                while (!me.ends_line () && me.has_tag (marker_tag)) {
                    me.forward_char ();
                }
                if (me.get_offset () > ls.get_offset ()) {
                    buffer.delete (ref ls, ref me);
                }
            }

            // Insert fresh markers.
            int counter = 0;
            string? prev = null;
            for (int ln = 0; ln < buffer.get_line_count (); ln++) {
                Gtk.TextIter ls;
                buffer.get_iter_at_line (out ls, ln);
                string? type = ls.has_tag (ul_tag) ? "ul"
                    : (ls.has_tag (ol_tag) ? "ol" : null);
                if (type == null) {
                    counter = 0;
                    prev = null;
                    continue;
                }
                if (type != prev) {
                    counter = 0;
                }
                counter++;
                string text = (type == "ol") ? "%d. ".printf (counter) : "• ";

                Gtk.TextIter at;
                buffer.get_iter_at_line (out at, ln);
                buffer.insert (ref at, text, -1);

                Gtk.TextIter ms, me;
                buffer.get_iter_at_line (out ms, ln);
                buffer.get_iter_at_line (out me, ln);
                me.forward_chars (text.char_count ());
                buffer.apply_tag (marker_tag, ms, me);
                buffer.apply_tag (type == "ol" ? ol_tag : ul_tag, ms, me);
                prev = type;
            }

            updating_markers = false;
        }

        // --- preview ----------------------------------------------------------

        private void update_preview () {
            var body = HtmlSerializer.buffer_to_html (buffer, links);
            var doc = "<!DOCTYPE html><html><head><meta charset=\"utf-8\">"
                + "<style>body{font-family:sans-serif;font-size:14px;margin:12px;}"
                + "a{color:#1c71d8;}</style></head><body>" + body + "</body></html>";
            web_view.load_html (doc, null);
        }

        // --- save -------------------------------------------------------------

        private void on_save () {
            var name = name_row.text.strip ();
            if (name == "") {
                name_row.add_css_class ("error");
                name_row.grab_focus ();
                return;
            }
            name_row.remove_css_class ("error");

            // If the user is on the source tab, commit their HTML edits first.
            if (current_tab == "source") {
                HtmlSerializer.html_to_buffer (source_view.buffer.text, buffer, links);
                refresh_list_markers ();
            }

            template.name = name;
            template.subject = subject_row.text;
            template.body_html = HtmlSerializer.buffer_to_html (buffer, links);
            var now = new DateTime.now_utc ().to_unix ();
            template.updated_at = now;

            try {
                if (is_new) {
                    template.created_at = now;
                    db.insert_template (template);
                } else {
                    db.update_template (template);
                }
            } catch (DatabaseError e) {
                warning ("Could not save template: %s", e.message);
                return;
            }

            saved ();
            close ();
        }
    }
}
