# Releasing

## 1. Check

- `tools/run_tests.sh` passes (run `full` before a big release).
- Bump the version: `GAME_VERSION` in `scripts/net/net_role.gd`
  (format `YYYY.MM.DD-hosted-N`). **Everyone in an online room needs the same
  version**, so bump it whenever gameplay or network code changes.
- Add a short entry to `docs/CHANGES.md` and a STATUS block to `docs/DEVLOG.md`.

## 2. Windows download → GitHub Releases

1. Make sure `eos_credentials.cfg` exists locally (it is exported into the game)
   and the plugin binaries are installed.
2. Project → Export → Windows Desktop → Export Project → `build/windows/BioBuzz3D.exe`.
3. Check the folder has `BioBuzz3D.exe`,
   `libeosg.windows.template_release.x86_64.dll`, `EOSSDK-Win64-Shipping.dll`,
   `xaudio2_9redist.dll`. Run it once: Play → Online should say
   "Ready to connect".
4. Zip the four files (plus a short README.txt) as `BIOBUZZ3D-windows-<version>.zip`.
5. Scan the zip at virustotal.com (keep the link for the release notes).
6. GitHub → Releases → Draft a new release → tag `v<version>` → attach the zip →
   paste the CHANGES entry → Publish.

## 3. Browser version

**GitHub Pages (automatic):** the workflow `.github/workflows/web.yml` builds the
browser version on every push to `main` and publishes it. One-time: repo
Settings → Pages → Source: **GitHub Actions**. The site is then at
`https://<org-or-user>.github.io/<repo>/`.

**itch.io (manual):** run `tools/build/export_web.sh`, zip the *contents* of
`build/web/` (index.html at the top level of the zip), and on itch.io:
Create new project → Kind: **HTML** → upload the zip → tick
"This file will be played in the browser" → Viewport 1280 × 720, tick
**Fullscreen button**. SharedArrayBuffer support is **not** needed.

**pandara.org:** upload the contents of `build/web/` to any folder on the site;
link to its `index.html`.

## Security notes

- `eos_credentials.cfg` holds the Epic **client secret**. It goes into the
  Windows build (that is how EOS game clients work — Epic's client policy only
  allows Connect, Lobbies and P2P), but it must never be in the public repo.
  If it leaks, rotate the secret in the Epic Developer Portal and re-export.
- The browser build contains no credentials.
