/* SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef MISSIVE_SMTP_H
#define MISSIVE_SMTP_H

#include <glib.h>

/* Test an SMTP login. Connects to host:port with the given encryption
 * ("smtps" / "starttls" / "none") and authenticates with username/password,
 * without sending any mail. Returns NULL on success, or a newly-allocated
 * error string (free with g_free) describing the failure. */
char *missive_smtp_test (const char *host, int port, const char *encryption,
                         const char *username, const char *password);

/* Send one already-serialized message (CRLF, dot-stuffed) over SMTP. The
 * envelope is mail_from plus every entry in recipients. Returns NULL on
 * success, or a newly-allocated error string (free with g_free). */
char *missive_smtp_send (const char *host, int port, const char *encryption,
                         const char *username, const char *password,
                         const char *mail_from,
                         char **recipients, int recipients_length,
                         const char *message, gsize message_len);

/* A reusable SMTP session: one connection, authenticated once, used to send
 * many messages (the campaign run). The connection is kept alive by libcurl
 * between sends. */
typedef struct _MissiveSmtpSession MissiveSmtpSession;

MissiveSmtpSession *missive_smtp_open (const char *host, int port,
                                       const char *encryption,
                                       const char *username,
                                       const char *password);

char *missive_smtp_session_send (MissiveSmtpSession *session,
                                 const char *mail_from,
                                 char **recipients, int recipients_length,
                                 const char *message, gsize message_len);

void missive_smtp_close (MissiveSmtpSession *session);

#endif /* MISSIVE_SMTP_H */
