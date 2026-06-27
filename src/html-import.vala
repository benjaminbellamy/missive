// SPDX-License-Identifier: GPL-3.0-or-later

namespace Missive {
    // Imports an external HTML file into a template body. It parses the document
    // with libxml2, inlines the CSS from every <style> block onto the matching
    // elements (premailer-style, honouring specificity and source order), keeps
    // only the content inside <body>, drops <style>/<script>/<link>/comments, and
    // pretty-prints the result so the HTML source stays easy to read and edit.
    //
    // Limitations, by design: at-rules (@media, @font-face, …) cannot be inlined
    // and are dropped; unsupported selectors (attribute, pseudo-class, sibling
    // combinators) are skipped rather than guessed at.
    public class HtmlImport : Object {

        // --- public entry -----------------------------------------------------

        public static string process (string html) {
            int options = Html.ParserOption.RECOVER | Html.ParserOption.NOERROR
                | Html.ParserOption.NOWARNING | Html.ParserOption.NONET
                | Html.ParserOption.COMPACT;
            Html.Doc* doc = Html.Doc.read_doc (html, "", null, options);
            if (doc == null) {
                return html; // unparseable: hand the original back untouched
            }

            Xml.Node* root = doc->get_root_element ();
            if (root == null) {
                delete doc;
                return html;
            }

            var rules = new GenericArray<StyleRule> ();
            collect_css (root, rules);

            Xml.Node* body = find_element (root, "body");
            if (body == null) {
                body = root; // a fragment with no <html>/<body> wrapper
            }

            apply_styles (body, rules);

            var sb = new StringBuilder ();
            serialize_children (body, 0, sb);

            delete doc;
            return sb.str.strip () + "\n";
        }

        // --- CSS model --------------------------------------------------------

        private class CssDecl {
            public string prop;
            public string value;
            public bool important;
        }

        private class Compound {
            public string? tag = null;          // null / "*" means any element
            public string[] classes = {};
            public string? id = null;
        }

        private class Selector {
            public Compound[] parts = {};       // left-to-right
            public bool[] child = {};           // child[i]: part i is a direct
                                                // child of part i-1 (i >= 1)
            public int specificity = 0;
            public bool valid = true;
        }

        private class StyleRule {
            public Selector selector;
            public CssDecl[] decls;
        }

        // A single matched declaration carried with the selector's weight so the
        // cascade can be replayed per element. `seq` is the document order in
        // which matches were gathered, a stable tiebreaker at equal specificity.
        private class Match {
            public int spec;
            public int seq;
            public CssDecl decl;
        }

        // --- gather stylesheets ----------------------------------------------

        private static void collect_css (Xml.Node* node, GenericArray<StyleRule> rules) {
            for (Xml.Node* n = node; n != null; n = n->next) {
                if (n->type == Xml.ElementType.ELEMENT_NODE) {
                    if (n->name.down () == "style") {
                        parse_stylesheet (n->get_content (), rules);
                    } else {
                        collect_css (n->children, rules);
                    }
                }
            }
        }

        // Scan a stylesheet into (selector, declarations) rules. Comments are
        // stripped, at-rules (and any block they own) are skipped. Works on raw
        // bytes so UTF-8 in declaration values survives verbatim.
        private static void parse_stylesheet (string css, GenericArray<StyleRule> rules) {
            uint8[] d = strip_css_comments (css);
            int n = d.length;
            int i = 0;
            while (i < n) {
                // Read the prelude up to '{', '}' or end.
                int start = i;
                while (i < n && d[i] != '{' && d[i] != '}') {
                    i++;
                }
                if (i >= n || d[i] == '}') {
                    // Stray text or closing brace with no block: skip it.
                    if (i < n) {
                        i++;
                    }
                    continue;
                }
                string prelude = slice (d, start, i).strip ();
                i++; // consume '{'

                if (prelude.has_prefix ("@")) {
                    // At-rule: skip its whole (possibly nested) block.
                    int depth = 1;
                    while (i < n && depth > 0) {
                        if (d[i] == '{') {
                            depth++;
                        } else if (d[i] == '}') {
                            depth--;
                        }
                        i++;
                    }
                    continue;
                }

                int block_start = i;
                while (i < n && d[i] != '}') {
                    i++;
                }
                string block = slice (d, block_start, i);
                if (i < n) {
                    i++; // consume '}'
                }

                var decls = parse_decls (block);
                if (decls.length == 0) {
                    continue;
                }
                foreach (var sel_text in prelude.split (",")) {
                    var sel = parse_selector (sel_text.strip ());
                    if (sel.valid && sel.parts.length > 0) {
                        rules.add (new StyleRule () {
                            selector = sel, decls = decls
                        });
                    }
                }
            }
        }

        // Split a declaration block into property/value pairs, respecting
        // parentheses so e.g. url(data:…;base64,…) is not split on its commas
        // or semicolons.
        private static CssDecl[] parse_decls(string block) {
            CssDecl[] result = {};
            uint8[] d = block.data;
            int n = d.length;
            int i = 0;
            while (i < n) {
                int start = i;
                int depth = 0;
                while (i < n && (d[i] != ';' || depth > 0)) {
                    if (d[i] == '(') {
                        depth++;
                    } else if (d[i] == ')' && depth > 0) {
                        depth--;
                    }
                    i++;
                }
                string piece = slice (d, start, i);
                if (i < n) {
                    i++; // consume ';'
                }

                // The property name is plain ASCII with no ':' or '(', so the
                // first colon is always the property/value separator.
                int colon = piece.index_of_char (':');
                if (colon < 0) {
                    continue;
                }
                string prop = piece.substring (0, colon).strip ().down ();
                string val = piece.substring (colon + 1).strip ();
                bool important = false;
                string low = val.down ();
                if (low.has_suffix ("!important")) {
                    val = val.substring (0, val.length - "!important".length).strip ();
                    important = true;
                } else {
                    int bang = low.last_index_of ("!");
                    if (bang >= 0 && low.substring (bang).strip ().has_prefix ("!important")) {
                        val = val.substring (0, bang).strip ();
                        important = true;
                    }
                }
                if (prop == "" || val == "") {
                    continue;
                }
                result += new CssDecl () {
                    prop = prop, value = val, important = important
                };
            }
            return result;
        }

        // --- selectors --------------------------------------------------------

        private static Selector parse_selector(string text) {
            var sel = new Selector ();
            if (text == "") {
                sel.valid = false;
                return sel;
            }
            // Reject anything we cannot match reliably rather than mis-applying.
            if (text.contains ("[") || text.contains ("]") || text.contains (":")
                || text.contains ("+") || text.contains ("~")
                || text.contains ("(") || text.contains (")")) {
                sel.valid = false;
                return sel;
            }

            string spaced = text.replace (">", " > ");
            string[] tokens = {};
            foreach (var t in spaced.split (" ")) {
                if (t.strip () != "") {
                    tokens += t.strip ();
                }
            }

            int spec = 0;
            bool pending_child = false;
            foreach (var tok in tokens) {
                if (tok == ">") {
                    pending_child = true;
                    continue;
                }
                var comp = parse_compound (tok);
                if (comp == null) {
                    sel.valid = false;
                    return sel;
                }
                sel.parts += comp;
                sel.child += pending_child;
                pending_child = false;
                if (comp.id != null) {
                    spec += 100;
                }
                spec += comp.classes.length * 10;
                if (comp.tag != null && comp.tag != "*") {
                    spec += 1;
                }
            }
            sel.specificity = spec;
            return sel;
        }

        // Parse one compound like "div.note.warn#lead" into tag/classes/id.
        private static Compound? parse_compound(string tok) {
            var comp = new Compound ();
            int i = 0;
            int n = tok.length;
            // Leading tag (or * or nothing).
            int start = i;
            while (i < n && tok[i] != '.' && tok[i] != '#') {
                i++;
            }
            if (i > start) {
                comp.tag = tok.substring (start, i - start).down ();
            }
            while (i < n) {
                char kind = tok[i];
                i++;
                start = i;
                while (i < n && tok[i] != '.' && tok[i] != '#') {
                    i++;
                }
                string name = tok.substring (start, i - start);
                if (name == "") {
                    return null;
                }
                if (kind == '.') {
                    comp.classes += name;
                } else { // '#'
                    if (comp.id != null) {
                        return null;
                    }
                    comp.id = name;
                }
            }
            return comp;
        }

        // --- matching ---------------------------------------------------------

        private static bool matches (Xml.Node* el, Selector sel) {
            int last = sel.parts.length - 1;
            if (last < 0 || !match_compound (el, sel.parts[last])) {
                return false;
            }
            Xml.Node* cur = el;
            for (int i = last - 1; i >= 0; i--) {
                if (sel.child[i + 1]) {
                    Xml.Node* parent = cur->parent;
                    if (parent == null
                        || parent->type != Xml.ElementType.ELEMENT_NODE
                        || !match_compound (parent, sel.parts[i])) {
                        return false;
                    }
                    cur = parent;
                } else {
                    Xml.Node* anc = cur->parent;
                    bool found = false;
                    while (anc != null && anc->type == Xml.ElementType.ELEMENT_NODE) {
                        if (match_compound (anc, sel.parts[i])) {
                            cur = anc;
                            found = true;
                            break;
                        }
                        anc = anc->parent;
                    }
                    if (!found) {
                        return false;
                    }
                }
            }
            return true;
        }

        private static bool match_compound (Xml.Node* el, Compound comp) {
            if (comp.tag != null && comp.tag != "*" && comp.tag != el->name.down ()) {
                return false;
            }
            if (comp.id != null) {
                string? idv = el->get_prop ("id");
                if (idv == null || idv != comp.id) {
                    return false;
                }
            }
            if (comp.classes.length > 0) {
                string classv = el->get_prop ("class") ?? "";
                string[] have = {};
                foreach (var c in classv.split (" ")) {
                    if (c.strip () != "") {
                        have += c.strip ();
                    }
                }
                foreach (var want in comp.classes) {
                    bool ok = false;
                    foreach (var h in have) {
                        if (h == want) {
                            ok = true;
                            break;
                        }
                    }
                    if (!ok) {
                        return false;
                    }
                }
            }
            return true;
        }

        // --- apply the cascade ------------------------------------------------

        private static void apply_styles (Xml.Node* node, GenericArray<StyleRule> rules) {
            for (Xml.Node* n = node->children; n != null; n = n->next) {
                if (n->type != Xml.ElementType.ELEMENT_NODE) {
                    continue;
                }
                string name = n->name.down ();
                if (name != "style" && name != "script") {
                    inline_element (n, rules);
                    apply_styles (n, rules);
                }
            }
        }

        private static void inline_element (Xml.Node* el, GenericArray<StyleRule> rules) {
            var matched = new GenericArray<Match> ();
            int seq = 0;
            for (int r = 0; r < rules.length; r++) {
                var rule = rules[r];
                if (matches (el, rule.selector)) {
                    foreach (var decl in rule.decls) {
                        matched.add (new Match () {
                            spec = rule.selector.specificity,
                            seq = seq++,
                            decl = decl
                        });
                    }
                }
            }

            string? inline_style = el->get_prop ("style");
            if (matched.length == 0 && inline_style == null) {
                return;
            }

            // Ascending cascade order: least specific / earliest first, so later
            // assignments win.
            matched.sort ((a, b) => {
                if (a.spec != b.spec) {
                    return a.spec - b.spec;
                }
                return a.seq - b.seq;
            });

            var keys = new GenericArray<string> ();
            var vals = new HashTable<string, string> (str_hash, str_equal);

            // 1. normal stylesheet declarations
            for (int k = 0; k < matched.length; k++) {
                if (!matched[k].decl.important) {
                    put (keys, vals, matched[k].decl.prop, matched[k].decl.value);
                }
            }
            // 2. the element's own inline style overrides normal stylesheet rules
            if (inline_style != null) {
                foreach (var decl in parse_decls (inline_style)) {
                    put (keys, vals, decl.prop, decl.value);
                }
            }
            // 3. !important stylesheet declarations override inline
            for (int k = 0; k < matched.length; k++) {
                if (matched[k].decl.important) {
                    put (keys, vals, matched[k].decl.prop, matched[k].decl.value);
                }
            }

            if (keys.length == 0) {
                return;
            }
            var sb = new StringBuilder ();
            for (int k = 0; k < keys.length; k++) {
                if (k > 0) {
                    sb.append (" ");
                }
                sb.append (keys[k]);
                sb.append (": ");
                sb.append (vals.get (keys[k]));
                sb.append (";");
            }
            el->set_prop ("style", sb.str);
        }

        private static void put (GenericArray<string> keys, HashTable<string, string> vals,
                          string prop, string val) {
            if (!vals.contains (prop)) {
                keys.add (prop);
            }
            vals.set (prop, val);
        }

        // --- pretty printer ---------------------------------------------------

        // Serialize a block element's children, grouping consecutive inline
        // content onto single indented lines and giving each block child its own
        // indented line.
        private static void serialize_children (Xml.Node* parent, int indent,
                                         StringBuilder sb) {
            string ind = indent_of (indent);
            var run = new StringBuilder ();
            for (Xml.Node* n = parent->children; n != null; n = n->next) {
                if (n->type == Xml.ElementType.ELEMENT_NODE
                    && is_block (n->name.down ())) {
                    flush_run (run, ind, sb);
                    serialize_block (n, indent, sb);
                } else {
                    serialize_inline (n, run);
                }
            }
            flush_run (run, ind, sb);
        }

        private static void flush_run (StringBuilder run, string ind, StringBuilder sb) {
            string text = collapse_ws (run.str);
            if (text != "") {
                sb.append (ind);
                sb.append (text);
                sb.append ("\n");
            }
            run.truncate (0);
        }

        private static void serialize_block (Xml.Node* el, int indent, StringBuilder sb) {
            string name = el->name.down ();
            string ind = indent_of (indent);
            sb.append (ind);
            sb.append ("<");
            sb.append (name);
            append_attrs (el, sb);

            if (is_void (name)) {
                sb.append (">\n");
                return;
            }
            sb.append (">");

            if (has_block_child (el)) {
                sb.append ("\n");
                serialize_children (el, indent + 1, sb);
                sb.append (ind);
            } else {
                var inner = new StringBuilder ();
                for (Xml.Node* c = el->children; c != null; c = c->next) {
                    serialize_inline (c, inner);
                }
                sb.append (collapse_ws (inner.str));
            }
            sb.append ("</");
            sb.append (name);
            sb.append (">\n");
        }

        private static void serialize_inline (Xml.Node* n, StringBuilder sb) {
            if (n->type == Xml.ElementType.TEXT_NODE) {
                sb.append (escape_text (n->content));
                return;
            }
            if (n->type != Xml.ElementType.ELEMENT_NODE) {
                return; // comments, PIs, etc. are dropped
            }
            string name = n->name.down ();
            if (name in SKIP) {
                return;
            }
            sb.append ("<");
            sb.append (name);
            append_attrs (n, sb);
            if (is_void (name)) {
                sb.append (">");
                return;
            }
            sb.append (">");
            for (Xml.Node* c = n->children; c != null; c = c->next) {
                serialize_inline (c, sb);
            }
            sb.append ("</");
            sb.append (name);
            sb.append (">");
        }

        private static void append_attrs (Xml.Node* el, StringBuilder sb) {
            for (Xml.Attr* a = el->properties; a != null; a = a->next) {
                string aname = a->name.down ();
                if (aname == "class") {
                    continue; // now redundant: its rules are inlined
                }
                string? val = el->get_prop (a->name);
                sb.append (" ");
                sb.append (aname);
                if (val != null) {
                    sb.append ("=\"");
                    sb.append (escape_attr (val));
                    sb.append ("\"");
                }
            }
        }

        private static bool has_block_child (Xml.Node* el) {
            for (Xml.Node* c = el->children; c != null; c = c->next) {
                if (c->type == Xml.ElementType.ELEMENT_NODE
                    && is_block (c->name.down ())) {
                    return true;
                }
            }
            return false;
        }

        // --- helpers ----------------------------------------------------------

        private static Xml.Node* find_element(Xml.Node* node, string name) {
            for (Xml.Node* n = node; n != null; n = n->next) {
                if (n->type == Xml.ElementType.ELEMENT_NODE) {
                    if (n->name.down () == name) {
                        return n;
                    }
                    Xml.Node* found = find_element (n->children, name);
                    if (found != null) {
                        return found;
                    }
                }
            }
            return null;
        }

        private const string[] SKIP = {
            "style", "script", "link", "meta", "title", "head", "base", "noscript"
        };

        private const string[] INLINE = {
            "a", "abbr", "b", "bdi", "bdo", "br", "button", "cite", "code", "data",
            "dfn", "em", "font", "i", "img", "input", "kbd", "label", "mark", "q",
            "s", "samp", "select", "small", "span", "strong", "sub", "sup",
            "textarea", "time", "u", "var", "wbr"
        };

        private const string[] VOID = {
            "area", "base", "br", "col", "embed", "hr", "img", "input", "link",
            "meta", "param", "source", "track", "wbr"
        };

        private static bool is_void (string name) {
            return name in VOID;
        }

        private static bool is_block (string name) {
            return !(name in INLINE) && !(name in SKIP);
        }

        private static string indent_of (int level) {
            return string.nfill (level * 2, ' ');
        }

        // Collapse runs of whitespace (incl. newlines) to single spaces, then
        // trim — turns wrapped/indented source into a tidy single line.
        private static string collapse_ws (string s) {
            var sb = new StringBuilder ();
            bool in_space = false;
            uint8[] d = s.data;
            for (int i = 0; i < d.length; i++) {
                uint8 c = d[i];
                if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
                    in_space = true;
                } else {
                    if (in_space && sb.len > 0) {
                        sb.append_c (' ');
                    }
                    in_space = false;
                    sb.append_c ((char) c);
                }
            }
            return sb.str;
        }

        private static string escape_text (string s) {
            return s.replace ("&", "&amp;").replace ("<", "&lt;").replace (">", "&gt;");
        }

        private static string escape_attr (string s) {
            return s.replace ("&", "&amp;").replace ("\"", "&quot;").replace ("<", "&lt;");
        }

        // Byte-accurate slice that preserves UTF-8 sequences verbatim.
        private static string slice (uint8[] d, int start, int end) {
            var sb = new StringBuilder ();
            for (int i = start; i < end && i < d.length; i++) {
                sb.append_c ((char) d[i]);
            }
            return sb.str;
        }

        // Remove /* … */ comments from CSS, returning the bytes.
        private static uint8[] strip_css_comments(string css) {
            uint8[] d = css.data;
            int n = d.length;
            var sb = new StringBuilder ();
            int i = 0;
            while (i < n) {
                if (i + 1 < n && d[i] == '/' && d[i + 1] == '*') {
                    i += 2;
                    while (i + 1 < n && !(d[i] == '*' && d[i + 1] == '/')) {
                        i++;
                    }
                    i += 2;
                } else {
                    sb.append_c ((char) d[i]);
                    i++;
                }
            }
            return sb.str.data;
        }
    }
}
