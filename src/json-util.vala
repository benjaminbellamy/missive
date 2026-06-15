// SPDX-License-Identifier: GPL-3.0-or-later

namespace Missive {
    // Small JSON helpers built on json-glib, used for the CSV columns_json
    // (ordered array of column names) and data_json (column -> value object).
    namespace JsonUtil {

        public string array_to_string (string[] items) {
            var builder = new Json.Builder ();
            builder.begin_array ();
            foreach (var item in items) {
                builder.add_string_value (item);
            }
            builder.end_array ();
            var generator = new Json.Generator ();
            generator.set_root (builder.get_root ());
            return generator.to_data (null);
        }

        public string[] string_to_array (string json) {
            string[] result = {};
            try {
                var parser = new Json.Parser ();
                parser.load_from_data (json, -1);
                var root = parser.get_root ();
                if (root != null && root.get_node_type () == Json.NodeType.ARRAY) {
                    var array = root.get_array ();
                    for (uint i = 0; i < array.get_length (); i++) {
                        result += array.get_string_element (i);
                    }
                }
            } catch (Error e) {
                warning ("Could not parse JSON array: %s", e.message);
            }
            return result;
        }

        // Serialize an object from parallel key/value arrays, preserving order.
        public string object_to_string (string[] keys, string[] values) {
            var builder = new Json.Builder ();
            builder.begin_object ();
            for (int i = 0; i < keys.length; i++) {
                builder.set_member_name (keys[i]);
                builder.add_string_value (i < values.length ? values[i] : "");
            }
            builder.end_object ();
            var generator = new Json.Generator ();
            generator.set_root (builder.get_root ());
            return generator.to_data (null);
        }

        // Parse a flat string->string object. Values that are not strings are
        // coerced to their string form so a stray number never breaks a lookup.
        public HashTable<string, string> string_to_object (string json) {
            var table = new HashTable<string, string> (str_hash, str_equal);
            try {
                var parser = new Json.Parser ();
                parser.load_from_data (json, -1);
                var root = parser.get_root ();
                if (root != null && root.get_node_type () == Json.NodeType.OBJECT) {
                    var obj = root.get_object ();
                    foreach (unowned string name in obj.get_members ()) {
                        var node = obj.get_member (name);
                        if (node.get_node_type () == Json.NodeType.VALUE
                            && node.get_value_type () == typeof (string)) {
                            table.set (name, node.get_string ());
                        }
                    }
                }
            } catch (Error e) {
                warning ("Could not parse JSON object: %s", e.message);
            }
            return table;
        }
    }
}
