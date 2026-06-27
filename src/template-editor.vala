// SPDX-License-Identifier: GPL-3.0-or-later

namespace Missive {
    // Rich-text template editor: a GtkTextView with a formatting toolbar
    // (bold/italic/underline/link/bullet/numbered) backed by GtkTextTags, plus
    // a live read-only WebKit preview of the serialized HTML. Editing happens in
    // GTK widgets; WebKit only renders the preview.
    [GtkTemplate (ui = "/fr/benjaminbellamy/missive/template-editor.ui")]
    public class TemplateEditor : Adw.Window {
        [GtkChild] private unowned Adw.EntryRow name_row;
        [GtkChild] private unowned Adw.EntryRow subject_row;
        [GtkChild] private unowned Adw.ComboRow csv_row;
        [GtkChild] private unowned Adw.ComboRow unsubscribe_row;
        [GtkChild] private unowned Gtk.FlowBox field_box;
        [GtkChild] private unowned Gtk.TextView body_view;
        [GtkChild] private unowned Gtk.TextView source_view;
        [GtkChild] private unowned Gtk.Box preview_box;
        [GtkChild] private unowned Adw.ViewStack edit_preview_stack;
        [GtkChild] private unowned Adw.ToastOverlay toast_overlay;
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
        private Gtk.TextTag spaced_tag;
        private Gtk.TextTag field_tag;
        private HashTable<unowned Gtk.TextTag, string> links;
        private WebKit.WebView web_view;
        private Adw.ViewStackPage edit_page;
        private GtkSource.Buffer source_buffer;
        private Gtk.TextTag source_markup_tag;
        private Gtk.TextTag source_field_tag;

        private bool syncing = false;
        private bool pending_bold = false;
        private bool pending_italic = false;
        private bool pending_underline = false;
        private bool updating_markers = false;
        private string current_tab = "edit";

        // Which representation holds the user's latest edits. The raw HTML source
        // and the rich buffer can each express things the other can't, so we
        // never overwrite the one the user touched most recently: hand-edited
        // HTML is saved verbatim and is never rewritten by the serializer.
        private enum Representation { BUFFER, SOURCE }
        private Representation last_edited = Representation.BUFFER;
        // Guards programmatic cross-view updates so they don't look like edits.
        private bool sync_in_progress = false;

        // Where an inserted {field} token should go (the last text widget used).
        private enum FocusTarget { SUBJECT, BODY, SOURCE }
        private FocusTarget last_focus = FocusTarget.BODY;
        private CsvSheet[] sheets = {};
        // Parallel to the unsubscribe combo: index 0 is "" (none).
        private string[] unsubscribe_codes;

        public TemplateEditor (Database db, Template? existing,
                               string imported_name = "", string imported_html = "") {
            Object ();
            this.db = db;
            this.is_new = existing == null;
            this.template = existing ?? new Template ();

            // Imported HTML seeds a brand-new template; it is treated exactly
            // like hand-edited source so the serializer never rewrites it.
            if (existing == null && imported_html != "") {
                template.name = imported_name;
                template.body_html = imported_html;
            }

            buffer = body_view.buffer;
            bold_tag = buffer.create_tag (HtmlSerializer.TAG_BOLD,
                "weight", Pango.Weight.BOLD);
            italic_tag = buffer.create_tag (HtmlSerializer.TAG_ITALIC,
                "style", Pango.Style.ITALIC);
            underline_tag = buffer.create_tag (HtmlSerializer.TAG_UNDERLINE,
                "underline", Pango.Underline.SINGLE);
            ul_tag = buffer.create_tag (HtmlSerializer.TAG_UL, "left-margin", 28);
            ol_tag = buffer.create_tag (HtmlSerializer.TAG_OL, "left-margin", 28);
            // Paragraph spacing: a line gets a blank line below it only when the
            // next line is not a list item, so list items stay tight (none
            // between, none before a list, one after it). Recomputed on edits.
            spaced_tag = buffer.create_tag (null, "pixels-below-lines", 12);
            // Non-editable visual prefix ("• " / "1. ") for list items.
            marker_tag = buffer.create_tag (HtmlSerializer.TAG_MARKER,
                "editable", false, "foreground", "#9a9996");
            // Highlight {field} tokens with a translucent yellow background; the
            // alpha keeps it legible over the white/grey/dark editor backgrounds.
            field_tag = make_field_tag (buffer);
            links = new HashTable<unowned Gtk.TextTag, string> (direct_hash, direct_equal);

            web_view = new WebKit.WebView () {
                hexpand = true,
                vexpand = true
            };
            preview_box.append (web_view);

            edit_page = edit_preview_stack.get_page (
                edit_preview_stack.get_child_by_name ("edit"));

            // Give the HTML source view a GtkSourceView buffer with HTML syntax
            // highlighting, following the light/dark theme. The buffer is a
            // Gtk.TextBuffer subclass, so all existing source_view.buffer uses
            // (load, sync, preview, save, token insertion) keep working.
            source_buffer = new GtkSource.Buffer (null);
            source_view.buffer = source_buffer;
            source_buffer.language =
                GtkSource.LanguageManager.get_default ().get_language ("html");
            apply_source_style_scheme ();
            Adw.StyleManager.get_default ().notify["dark"]
                .connect (apply_source_style_scheme);
            // Source highlighting: grey behind the HTML markup (<…>) and yellow
            // behind {field} tokens, leaving the actual text on the plain (white)
            // background. The field tag is created last so it wins where a token
            // sits inside a tag (e.g. an attribute value).
            source_markup_tag = make_markup_tag (source_buffer);
            source_field_tag = make_field_tag (source_buffer);

            title = is_new ? _("New Template") : _("Edit Template");
            name_row.text = template.name;
            subject_row.text = template.subject;
            if (template.body_html != "") {
                HtmlSerializer.html_to_buffer (template.body_html, buffer, links);
                refresh_list_markers ();
                highlight_fields (buffer, field_tag);
                // The stored HTML is the user's own; keep it as the canonical
                // copy so reopening and saving never rewrites it. It only gets
                // re-serialized if the user actually edits the rich buffer.
                source_view.buffer.text = template.body_html;
                highlight_source ();
                last_edited = Representation.SOURCE;
            }

            cancel_button.clicked.connect (() => close ());
            save_button.clicked.connect (on_save);

            // Adw.Window (unlike Adw.Dialog) doesn't close on Escape; restore it.
            var esc = new Gtk.EventControllerKey ();
            esc.key_pressed.connect ((keyval) => {
                if (keyval == Gdk.Key.Escape) {
                    close ();
                    return true;
                }
                return false;
            });
            ((Gtk.Widget) this).add_controller (esc);
            bold_button.toggled.connect (on_bold);
            italic_button.toggled.connect (on_italic);
            underline_button.toggled.connect (on_underline);
            link_button.clicked.connect (on_link);
            bullet_button.clicked.connect (() => toggle_list (ul_tag, ol_tag));
            numbered_button.clicked.connect (() => toggle_list (ol_tag, ul_tag));

            buffer.insert_text.connect_after (on_insert_after);
            buffer.notify["cursor-position"].connect (sync_buttons);
            buffer.changed.connect (() => {
                if (!updating_markers) {
                    update_spacing ();
                }
                if (!sync_in_progress && !updating_markers) {
                    last_edited = Representation.BUFFER;
                    highlight_fields (buffer, field_tag);
                }
            });

            // A direct edit in the HTML source tab makes the source canonical.
            source_view.buffer.changed.connect (() => {
                if (!sync_in_progress) {
                    last_edited = Representation.SOURCE;
                    refresh_edit_availability ();
                    highlight_source ();
                }
            });

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
            csv_row.notify["selected"].connect (populate_field_chips);

            // Unsubscribe-link language: None plus one entry per shipped language.
            unsubscribe_row.model = new Gtk.StringList (
                Lang.picker_labels (_("None"), out unsubscribe_codes));
            for (uint i = 0; i < unsubscribe_codes.length; i++) {
                if (unsubscribe_codes[i] == template.unsubscribe_lang) {
                    unsubscribe_row.selected = i;
                    break;
                }
            }
            unsubscribe_row.notify["selected"].connect (populate_field_chips);
            populate_field_chips ();

            // Imported/loaded HTML may be richer than the rich editor can hold
            // (tables, divs, inline styles); hide the "Edit" tab in that case so
            // it never shows a buffer that silently dropped most of the content.
            refresh_edit_availability ();
        }

        // A {field}-token background tag (translucent yellow) for the given
        // buffer. A tag belongs to one buffer, so the rich and source buffers
        // each get their own. Alpha keeps it legible on light and dark themes.
        private Gtk.TextTag make_field_tag (Gtk.TextBuffer buf) {
            var tag = buf.create_tag ("field");
            var yellow = Gdk.RGBA ();
            yellow.parse ("rgba(247,224,70,0.40)");
            tag.background_rgba = yellow;
            return tag;
        }

        // A background tag (translucent grey) for HTML markup spans (<…>).
        private Gtk.TextTag make_markup_tag (Gtk.TextBuffer buf) {
            var tag = buf.create_tag ("markup");
            var grey = Gdk.RGBA ();
            grey.parse ("rgba(128,128,128,0.18)");
            tag.background_rgba = grey;
            return tag;
        }

        // Apply a tag over each (char-offset) span. Tag changes don't emit
        // "changed", so this is safe to call from change handlers.
        private void apply_ranges (Gtk.TextBuffer buf, Gtk.TextTag tag,
                                   Substitution.TokenSpan[] spans) {
            foreach (var s in spans) {
                Gtk.TextIter si, ei;
                buf.get_iter_at_offset (out si, s.start);
                buf.get_iter_at_offset (out ei, s.end);
                buf.apply_tag (tag, si, ei);
            }
        }

        // Rich editor: highlight {field} tokens only (no markup is shown there).
        private void highlight_fields (Gtk.TextBuffer buf, Gtk.TextTag tag) {
            Gtk.TextIter a, b;
            buf.get_bounds (out a, out b);
            buf.remove_tag (tag, a, b);
            apply_ranges (buf, tag, Substitution.token_ranges (buf.get_text (a, b, true)));
        }

        // Source editor: grey behind markup, yellow behind {field} tokens.
        private void highlight_source () {
            Gtk.TextIter a, b;
            source_buffer.get_bounds (out a, out b);
            source_buffer.remove_tag (source_markup_tag, a, b);
            source_buffer.remove_tag (source_field_tag, a, b);
            string text = source_buffer.get_text (a, b, true);
            apply_ranges (source_buffer, source_markup_tag, markup_ranges (text));
            apply_ranges (source_buffer, source_field_tag, Substitution.token_ranges (text));
        }

        // Character offsets (end exclusive) of every <…> markup span.
        private static Substitution.TokenSpan[] markup_ranges (string text) {
            Substitution.TokenSpan[] result = {};
            unichar[] chars = {};
            int idx = 0;
            unichar c;
            while (text.get_next_char (ref idx, out c)) {
                chars += c;
            }
            int n = chars.length;
            int i = 0;
            while (i < n) {
                if (chars[i] == '<') {
                    int j = -1;
                    for (int k = i + 1; k < n; k++) {
                        if (chars[k] == '>') { j = k; break; }
                    }
                    if (j < 0) {
                        break; // no closing '>': leave the rest unmarked
                    }
                    result += Substitution.TokenSpan () { start = i, end = j + 1 };
                    i = j + 1;
                } else {
                    i++;
                }
            }
            return result;
        }

        // Pick the source-view colour scheme that matches the current theme.
        private void apply_source_style_scheme () {
            var mgr = GtkSource.StyleSchemeManager.get_default ();
            bool dark = Adw.StyleManager.get_default ().dark;
            var scheme = mgr.get_scheme (dark ? "Adwaita-dark" : "Adwaita");
            if (scheme == null) {
                scheme = mgr.get_scheme (dark ? "classic-dark" : "classic");
            }
            source_buffer.style_scheme = scheme;
        }

        // Show the rich "Edit" tab only while the canonical content can be
        // round-tripped through the buffer. When the source is canonical and not
        // representable, hide the tab and fall back to the source view.
        private void refresh_edit_availability () {
            bool ok = last_edited != Representation.SOURCE
                || HtmlSerializer.is_rich_representable (source_view.buffer.text);
            edit_page.visible = ok;
            if (!ok && edit_preview_stack.visible_child_name == "edit") {
                edit_preview_stack.visible_child_name = "source";
            }
        }

        private void track_focus (Gtk.Widget widget, FocusTarget target) {
            var controller = new Gtk.EventControllerFocus ();
            controller.enter.connect (() => {
                last_focus = target;
            });
            widget.add_controller (controller);
        }

        // --- CSV field picker -------------------------------------------------

        private void populate_field_chips () {
            Gtk.Widget? child;
            while ((child = field_box.get_first_child ()) != null) {
                field_box.remove (child);
            }

            bool any = false;
            // The reserved {unsubscribe} field, shown only once a language is set.
            if (unsubscribe_enabled ()) {
                field_box.append (make_field_button ("unsubscribe"));
                any = true;
            }
            // CSV columns of the selected sheet.
            uint selected = csv_row.selected;
            if (selected != 0 && selected <= sheets.length) {
                foreach (var column in
                         JsonUtil.string_to_array (sheets[selected - 1].columns_json)) {
                    field_box.append (make_field_button (column));
                    any = true;
                }
            }
            field_box.visible = any;
        }

        private bool unsubscribe_enabled () {
            return unsubscribe_row.selected != 0;
        }

        // The editor is its own Adw.Window, so it shows toasts in its own overlay
        // rather than the main window's.
        private void toast (string text) {
            toast_overlay.add_toast (new Adw.Toast (text));
        }

        // Whether a {name} token appears in the text (respecting {{ }} escapes).
        private static bool has_token (string text, string name) {
            foreach (var t in Substitution.find_tokens (text)) {
                if (t == name) {
                    return true;
                }
            }
            return false;
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
            if (target == "source") {
                // Only regenerate the HTML source from the rich buffer when the
                // buffer holds the newer edits. If the user last edited the
                // source by hand, leave it exactly as they typed it.
                if (last_edited == Representation.BUFFER) {
                    sync_in_progress = true;
                    source_view.buffer.text = HtmlSerializer.buffer_to_html (buffer, links);
                    sync_in_progress = false;
                    highlight_source ();
                }
            } else if (target == "edit") {
                // Bring the rich editor up to date with hand-edited HTML.
                if (last_edited == Representation.SOURCE) {
                    sync_in_progress = true;
                    HtmlSerializer.html_to_buffer (source_view.buffer.text, buffer, links);
                    refresh_list_markers ();
                    sync_in_progress = false;
                    highlight_fields (buffer, field_tag);
                }
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
            last_edited = Representation.BUFFER;
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
            // If the cursor sits on an existing link, edit it (and offer to
            // remove it); otherwise insert a new one over the selection.
            Gtk.TextIter span_start, span_end;
            Gtk.TextTag? existing = link_tag_at_cursor (out span_start, out span_end);

            var entry = new Gtk.Entry () {
                text = existing != null ? links.lookup (existing) : "",
                placeholder_text = "https://",
                hexpand = true,
                activates_default = true
            };
            var dialog = new Adw.AlertDialog (
                existing != null ? _("Edit Link") : _("Insert Link"), null);
            dialog.set_extra_child (entry);
            dialog.add_response ("cancel", _("Cancel"));
            if (existing != null) {
                dialog.add_response ("remove", _("Remove Link"));
                dialog.set_response_appearance ("remove",
                                                Adw.ResponseAppearance.DESTRUCTIVE);
            }
            dialog.add_response ("insert", existing != null ? _("Save") : _("Insert"));
            dialog.set_response_appearance ("insert", Adw.ResponseAppearance.SUGGESTED);
            dialog.default_response = "insert";
            dialog.close_response = "cancel";
            dialog.response.connect ((response) => {
                if (response == "remove" && existing != null) {
                    last_edited = Representation.BUFFER;
                    buffer.remove_tag (existing, span_start, span_end);
                    links.remove (existing);
                    return;
                }
                if (response != "insert") {
                    return;
                }
                last_edited = Representation.BUFFER;
                var url = entry.text.strip ();
                if (url == "") {
                    return;
                }
                if (existing != null) {
                    // Same span and styling, just point it at the new URL.
                    links.replace (existing, url);
                } else {
                    apply_link (url);
                }
            });
            dialog.present (this);
            entry.grab_focus ();
        }

        // The link tag (if any) covering the cursor, with its full run in
        // start/end. Returns null when the cursor is not on a link.
        private Gtk.TextTag? link_tag_at_cursor (out Gtk.TextIter start,
                                                 out Gtk.TextIter end) {
            Gtk.TextIter at;
            buffer.get_iter_at_mark (out at, buffer.get_insert ());
            start = at;
            end = at;
            Gtk.TextTag? found = null;
            foreach (var tag in at.get_tags ()) {
                if (links.contains (tag)) {
                    found = tag;
                    break;
                }
            }
            if (found != null) {
                if (!start.starts_tag (found)) {
                    start.backward_to_tag_toggle (found);
                }
                if (!end.ends_tag (found)) {
                    end.forward_to_tag_toggle (found);
                }
            }
            return found;
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
            last_edited = Representation.BUFFER;
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
            update_spacing ();
        }

        // Give each line a blank line below it, except between two consecutive
        // list items: that keeps items tight while still leaving one blank line
        // before a list and one after it. Cheap enough to run on every edit.
        private void update_spacing () {
            int lines = buffer.get_line_count ();
            for (int ln = 0; ln < lines; ln++) {
                Gtk.TextIter ls;
                buffer.get_iter_at_line (out ls, ln);
                Gtk.TextIter le;
                buffer.get_iter_at_line (out le, ln);
                if (!le.forward_line ()) {
                    buffer.get_end_iter (out le);
                }
                bool is_list = ls.has_tag (ul_tag) || ls.has_tag (ol_tag);
                bool next_is_list = false;
                if (ln + 1 < lines) {
                    Gtk.TextIter ns;
                    buffer.get_iter_at_line (out ns, ln + 1);
                    next_is_list = ns.has_tag (ul_tag) || ns.has_tag (ol_tag);
                }
                if (is_list && next_is_list) {
                    buffer.remove_tag (spaced_tag, ls, le);
                } else {
                    buffer.apply_tag (spaced_tag, ls, le);
                }
            }
        }

        // --- preview ----------------------------------------------------------

        private void update_preview () {
            var body = last_edited == Representation.SOURCE
                ? source_view.buffer.text
                : HtmlSerializer.buffer_to_html (buffer, links);
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

            var subject = subject_row.text.strip ();
            if (subject == "") {
                subject_row.add_css_class ("error");
                subject_row.grab_focus ();
                toast (_("A subject is required."));
                return;
            }
            subject_row.remove_css_class ("error");

            // Save whichever representation the user last edited. Hand-edited
            // HTML is stored exactly as typed — the serializer never touches it.
            var body_html = last_edited == Representation.SOURCE
                ? source_view.buffer.text
                : HtmlSerializer.buffer_to_html (buffer, links);

            // If an unsubscribe link is enabled, the {unsubscribe} placeholder
            // must be present somewhere in the body, or the link would never
            // appear in the sent message.
            if (unsubscribe_enabled () && !has_token (body_html, "unsubscribe")) {
                edit_preview_stack.visible_child_name =
                    last_edited == Representation.SOURCE ? "source" : "edit";
                toast (_("Insert the {unsubscribe} field into the body, "
                    + "or set Unsubscribe Link to None."));
                return;
            }

            template.name = name;
            template.subject = subject_row.text;
            template.body_html = body_html;
            template.unsubscribe_lang = unsubscribe_codes[unsubscribe_row.selected];
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
