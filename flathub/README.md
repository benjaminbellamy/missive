# Flathub submission

This directory holds the manifest used to publish Missive on
[Flathub](https://flathub.org). It is **prepared, not submitted**.

- `fr.bellamy.missive.json` — the Flathub manifest. Unlike
  `build-aux/fr.bellamy.missive.json` (which builds the working tree via
  `type: dir` for local development), this one pulls the app from the tagged
  release (`git` source, pinned to a tag + commit), as Flathub requires.

## Before submitting: app ID / domain

Flathub requires the app ID to be a reverse-DNS name you can prove you control:

- **`fr.bellamy.missive`** — requires control of the `bellamy.fr` domain and a
  verification step (a DNS `TXT` record or a file under `/.well-known/`).
- If you don't control that domain, Flathub expects a code-hosting ID such as
  **`io.github.benjaminbellamy.missive`**. Renaming touches the GSchema id, the
  GResource base path (`/io/github/benjaminbellamy/missive`), the desktop /
  metainfo / icon file names and the manifest — doable, but a deliberate change.

Decide this first; everything else is in place.

## How to submit

1. Fork [`flathub/flathub`](https://github.com/flathub/flathub) and create a
   branch named after the app ID.
2. Copy `fr.bellamy.missive.json` to the repo root and open a pull request
   against the `new-pr` branch (see the Flathub
   [submission docs](https://docs.flathub.org/docs/for-app-authors/submission)).
3. Flathub's bot builds and reviews it.

## Local checks (already passing)

```sh
# manifest lint — no errors
flatpak run --command=flatpak-builder-lint org.flatpak.Builder manifest flathub/fr.bellamy.missive.json

# build from the pinned tag and lint the result
flatpak-builder --force-clean --repo=repo-flathub build-flathub flathub/fr.bellamy.missive.json
flatpak run --command=flatpak-builder-lint org.flatpak.Builder repo repo-flathub
```

Notes on the remaining linter output:

- `appstream-external-screenshot-url` / `appstream-screenshots-not-mirrored-in-ostree`
  — **expected locally**. Flathub's build service mirrors screenshots to its own
  CDN, after which these pass; nothing to fix here.
- `runtime-update-available-to-org.gnome.Platform-50` — advisory. The app
  targets GNOME 49; bumping `runtime-version` to `50` before submission is
  recommended once an SDK 50 build has been tested.

## Differences from the dev manifest

- App source is `git` (tag `v0.1.0`) instead of a local directory.
- `--share=ipc` added (required alongside `--socket=fallback-x11`).
- Redundant `--talk-name=org.freedesktop.portal.*` entries removed (portals do
  not need an explicit talk-name).
- `WEBKIT_DISABLE_DMABUF_RENDERER` is **not** set (it's a local VM workaround;
  on real hardware WebKit's DMA-BUF renderer works, and Flathub prefers not
  disabling it). The dev manifest keeps it.
