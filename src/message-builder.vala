// SPDX-License-Identifier: GPL-3.0-or-later

namespace Missive {
    // Builds a personalized multipart/alternative message with GMime. Headers
    // are set through GMime so encoding (RFC 2047 display names, UTF-8 subject)
    // is correct. BCC is never written to the message headers.
    public class MessageBuilder : Object {

        // Substitute tokens, append the identity signature, and assemble the
        // MIME message. Unknown tokens encountered are recorded in `unknown`.
        public static GMime.Message compose (Identity identity,
                                             string subject_template,
                                             string body_html_template,
                                             HashTable<string, string> values,
                                             string to_address,
                                             string[] cc,
                                             HashTable<string, bool> unknown,
                                             bool include_signature = true,
                                             string unsubscribe_lang = "") {
            string subject = Substitution.apply (subject_template, values, false, unknown);

            // Resolve the reserved {unsubscribe} token to a localized mailto link
            // (raw HTML, so field substitution does not escape it). When disabled
            // the token is simply stripped. The language is the campaign's choice,
            // not the running UI locale.
            string unsub_link = "";
            if (unsubscribe_lang != "" && identity.from_email != "") {
                string subj = GLib.Uri.escape_string (
                    Lang.unsubscribe_subject (unsubscribe_lang), null, false);
                string label = Lang.unsubscribe_label (unsubscribe_lang)
                    .replace ("&", "&amp;").replace ("<", "&lt;").replace (">", "&gt;");
                unsub_link = "<a href=\"mailto:" + identity.from_email
                    + "?subject=" + subj + "\">" + label + "</a>";
            }
            string resolved = Substitution.replace_reserved (
                body_html_template, "unsubscribe", unsub_link);
            string body = Substitution.apply (resolved, values, true, unknown);

            string full_html = body;
            if (include_signature && identity.signature_html != "") {
                full_html += "\n" + identity.signature_html;
            }
            string plain = HtmlSerializer.html_to_plain (full_html);

            // Webmail clients reset <p> margins (and strip <head>/<style>), so
            // paragraphs render with no gap. Force spacing with an inline style
            // on each paragraph, which survives. Our serializer always emits a
            // bare "<p>" and substituted values are HTML-escaped, so this only
            // matches structural paragraphs.
            string html = full_html.replace ("<p>", "<p style=\"margin:0 0 1em 0;\">");

            var message = new GMime.Message (true);
            message.add_mailbox (GMime.AddressType.FROM,
                                 identity.from_name, identity.from_email);
            message.add_mailbox (GMime.AddressType.TO, "", to_address);
            foreach (var addr in cc) {
                var a = addr.strip ();
                if (a != "") {
                    message.add_mailbox (GMime.AddressType.CC, "", a);
                }
            }
            message.set_subject (subject, "utf-8");
            message.set_date (new DateTime.now_local ());

            // The constructor does not create a Message-ID; derive one from the
            // sender's domain (RFC 5322 requires this header).
            int at = identity.from_email.index_of_char ('@');
            string fqdn = (at >= 0 && at + 1 < identity.from_email.length)
                ? identity.from_email.substring (at + 1) : "localhost";
            message.set_message_id (GMime.utils_generate_message_id (fqdn));

            // text/plain first, text/html last (preferred alternative).
            var alternative = new GMime.Multipart.with_subtype ("alternative");
            alternative.add (make_utf8_part ("plain", plain));
            alternative.add (make_utf8_part ("html", html));
            message.set_mime_part (alternative);

            return message;
        }

        // Build a UTF-8 text part. The raw UTF-8 bytes are set as the content
        // (with charset=utf-8) so GMime does not down-convert to ISO-8859-1;
        // they are quoted-printable encoded on output.
        private static GMime.TextPart make_utf8_part (string subtype, string text) {
            var part = new GMime.TextPart.with_subtype (subtype);
            part.set_content_type_parameter ("charset", "utf-8");
            var stream = new GMime.StreamMem.with_buffer (text.data);
            var wrapper = new GMime.DataWrapper.with_stream (
                stream, GMime.ContentEncoding.DEFAULT);
            part.set_content (wrapper);
            part.set_content_encoding (GMime.ContentEncoding.QUOTEDPRINTABLE);
            return part;
        }

        // Serialize a message to a MIME string (for the dry run and sending).
        public static string to_mime_string (GMime.Message message) {
            var stream = new GMime.StreamMem ();
            message.write_to_stream (null, stream);
            unowned GLib.ByteArray ba = stream.get_byte_array ();
            var bytes = new uint8[ba.len + 1];
            if (ba.len > 0) {
                Memory.copy (bytes, ba.data, ba.len);
            }
            bytes[ba.len] = 0;
            return (string) bytes;
        }
    }
}
