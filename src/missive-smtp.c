/* SPDX-License-Identifier: GPL-3.0-or-later */
#include "missive-smtp.h"

#include <curl/curl.h>
#include <string.h>

static void
ensure_init (void)
{
  static gsize init_once = 0;
  if (g_once_init_enter (&init_once))
    {
      curl_global_init (CURL_GLOBAL_DEFAULT);
      g_once_init_leave (&init_once, 1);
    }
}

/* Apply the encryption mode and certificate verification to an easy handle. */
static char *
apply_url_and_tls (CURL *curl, const char *host, int port,
                   const char *encryption)
{
  gboolean implicit_tls = (g_strcmp0 (encryption, "smtps") == 0);
  const char *scheme = implicit_tls ? "smtps" : "smtp";
  char *url = g_strdup_printf ("%s://%s:%d", scheme, host ? host : "", port);
  curl_easy_setopt (curl, CURLOPT_URL, url);

  if (implicit_tls || g_strcmp0 (encryption, "starttls") == 0)
    curl_easy_setopt (curl, CURLOPT_USE_SSL, (long) CURLUSESSL_ALL);
  else
    curl_easy_setopt (curl, CURLOPT_USE_SSL, (long) CURLUSESSL_NONE);

  curl_easy_setopt (curl, CURLOPT_SSL_VERIFYPEER, 1L);
  curl_easy_setopt (curl, CURLOPT_SSL_VERIFYHOST, 2L);
  return url;
}

char *
missive_smtp_test (const char *host, int port, const char *encryption,
                   const char *username, const char *password)
{
  ensure_init ();

  if (host == NULL || host[0] == '\0')
    return g_strdup ("No SMTP host set.");

  CURL *curl = curl_easy_init ();
  if (curl == NULL)
    return g_strdup ("Could not initialize the network library.");

  char errbuf[CURL_ERROR_SIZE];
  errbuf[0] = '\0';

  char *url = apply_url_and_tls (curl, host, port, encryption);
  curl_easy_setopt (curl, CURLOPT_USERNAME, username ? username : "");
  curl_easy_setopt (curl, CURLOPT_PASSWORD, password ? password : "");
  curl_easy_setopt (curl, CURLOPT_ERRORBUFFER, errbuf);
  /* CONNECT_ONLY runs the SMTP handshake through authentication, then stops. */
  curl_easy_setopt (curl, CURLOPT_CONNECT_ONLY, 1L);
  curl_easy_setopt (curl, CURLOPT_CONNECTTIMEOUT, 15L);
  curl_easy_setopt (curl, CURLOPT_TIMEOUT, 30L);

  CURLcode res = curl_easy_perform (curl);

  char *result = NULL;
  if (res != CURLE_OK)
    {
      const char *msg = (errbuf[0] != '\0') ? errbuf : curl_easy_strerror (res);
      result = g_strdup (msg);
    }

  g_free (url);
  curl_easy_cleanup (curl);
  return result;
}

struct upload_state
{
  const char *data;
  gsize len;
  gsize pos;
};

static size_t
read_callback (char *buffer, size_t size, size_t nitems, void *userp)
{
  struct upload_state *up = userp;
  size_t capacity = size * nitems;
  gsize remaining = up->len - up->pos;
  size_t n = remaining < capacity ? remaining : capacity;
  if (n > 0)
    {
      memcpy (buffer, up->data + up->pos, n);
      up->pos += n;
    }
  return n;
}

char *
missive_smtp_send (const char *host, int port, const char *encryption,
                   const char *username, const char *password,
                   const char *mail_from,
                   char **recipients, int recipients_length,
                   const char *message, gsize message_len)
{
  ensure_init ();

  if (host == NULL || host[0] == '\0')
    return g_strdup ("No SMTP host set.");
  if (recipients_length <= 0)
    return g_strdup ("No recipients.");

  CURL *curl = curl_easy_init ();
  if (curl == NULL)
    return g_strdup ("Could not initialize the network library.");

  char errbuf[CURL_ERROR_SIZE];
  errbuf[0] = '\0';

  char *url = apply_url_and_tls (curl, host, port, encryption);
  curl_easy_setopt (curl, CURLOPT_USERNAME, username ? username : "");
  curl_easy_setopt (curl, CURLOPT_PASSWORD, password ? password : "");
  curl_easy_setopt (curl, CURLOPT_ERRORBUFFER, errbuf);
  curl_easy_setopt (curl, CURLOPT_MAIL_FROM, mail_from ? mail_from : "");

  struct curl_slist *rcpt = NULL;
  for (int i = 0; i < recipients_length; i++)
    {
      if (recipients[i] != NULL && recipients[i][0] != '\0')
        rcpt = curl_slist_append (rcpt, recipients[i]);
    }
  curl_easy_setopt (curl, CURLOPT_MAIL_RCPT, rcpt);

  struct upload_state up = { message, message_len, 0 };
  curl_easy_setopt (curl, CURLOPT_UPLOAD, 1L);
  curl_easy_setopt (curl, CURLOPT_READFUNCTION, read_callback);
  curl_easy_setopt (curl, CURLOPT_READDATA, &up);
  curl_easy_setopt (curl, CURLOPT_CONNECTTIMEOUT, 20L);
  curl_easy_setopt (curl, CURLOPT_TIMEOUT, 120L);

  CURLcode res = curl_easy_perform (curl);

  char *result = NULL;
  if (res != CURLE_OK)
    {
      const char *msg = (errbuf[0] != '\0') ? errbuf : curl_easy_strerror (res);
      result = g_strdup (msg);
    }

  curl_slist_free_all (rcpt);
  g_free (url);
  curl_easy_cleanup (curl);
  return result;
}

struct _MissiveSmtpSession
{
  CURL *curl;
};

MissiveSmtpSession *
missive_smtp_open (const char *host, int port, const char *encryption,
                   const char *username, const char *password)
{
  ensure_init ();

  MissiveSmtpSession *session = g_new0 (MissiveSmtpSession, 1);
  session->curl = curl_easy_init ();
  if (session->curl != NULL)
    {
      char *url = apply_url_and_tls (session->curl, host, port, encryption);
      curl_easy_setopt (session->curl, CURLOPT_USERNAME, username ? username : "");
      curl_easy_setopt (session->curl, CURLOPT_PASSWORD, password ? password : "");
      curl_easy_setopt (session->curl, CURLOPT_CONNECTTIMEOUT, 20L);
      g_free (url);
    }
  return session;
}

char *
missive_smtp_session_send (MissiveSmtpSession *session, const char *mail_from,
                           char **recipients, int recipients_length,
                           const char *message, gsize message_len)
{
  if (session == NULL || session->curl == NULL)
    return g_strdup ("The SMTP session is not open.");
  if (recipients_length <= 0)
    return g_strdup ("No recipients.");

  CURL *curl = session->curl;
  char errbuf[CURL_ERROR_SIZE];
  errbuf[0] = '\0';

  curl_easy_setopt (curl, CURLOPT_ERRORBUFFER, errbuf);
  curl_easy_setopt (curl, CURLOPT_MAIL_FROM, mail_from ? mail_from : "");

  struct curl_slist *rcpt = NULL;
  for (int i = 0; i < recipients_length; i++)
    {
      if (recipients[i] != NULL && recipients[i][0] != '\0')
        rcpt = curl_slist_append (rcpt, recipients[i]);
    }
  curl_easy_setopt (curl, CURLOPT_MAIL_RCPT, rcpt);

  struct upload_state up = { message, message_len, 0 };
  curl_easy_setopt (curl, CURLOPT_UPLOAD, 1L);
  curl_easy_setopt (curl, CURLOPT_READFUNCTION, read_callback);
  curl_easy_setopt (curl, CURLOPT_READDATA, &up);
  curl_easy_setopt (curl, CURLOPT_TIMEOUT, 120L);

  CURLcode res = curl_easy_perform (curl);

  char *result = NULL;
  if (res != CURLE_OK)
    {
      const char *msg = (errbuf[0] != '\0') ? errbuf : curl_easy_strerror (res);
      result = g_strdup (msg);
    }

  curl_slist_free_all (rcpt);
  return result;
}

void
missive_smtp_close (MissiveSmtpSession *session)
{
  if (session == NULL)
    return;
  if (session->curl != NULL)
    curl_easy_cleanup (session->curl);
  g_free (session);
}
