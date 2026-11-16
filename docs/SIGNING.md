# Signing, notarizing & releasing Vesta

The GitHub Actions workflow `.github/workflows/release.yml` builds `Vesta.app`,
signs it with your **Developer ID**, **notarizes** it with Apple, staples the
ticket, packages a DMG, and attaches it to a GitHub Release. Tag a commit
`vX.Y.Z` (or run the workflow manually) to trigger it.

You must add a few secrets first — Apple won't let CI sign as you without them.
GhosttyKit is fetched automatically by SwiftPM; the only optional build input is
the gitignored ghostty themes (see §1).

## 1. Build inputs (repo **Variables** — Settings ▸ Secrets and variables ▸ Actions ▸ Variables)

`GhosttyKit.xcframework` is fetched automatically by SwiftPM via a
checksum-verified `binaryTarget` in `Package.swift` — **no variable needed**. The
only optional CI input is the vendored ghostty themes (gitignored):

| Variable | Value |
|---|---|
| `GHOSTTY_RESOURCES_URL` | *(optional)* URL to a tar.gz/zip of ghostty's `Resources/ghostty` dir (the bundled themes). If omitted, named themes won't bundle. |

> GhosttyKit bumps are automatic: `.github/workflows/ghostty-watch.yml` (Mondays, or
> run it by hand) notices a new ghostty stable tag, builds the xcframework, checks
> Vesta builds + selfchecks against it, publishes `ghostkit-N` (`--latest=false`),
> bumps `Package.swift` + `.ghostty-version` on `main`, tags the next patch version and
> dispatches the release. If the build breaks (ghostty changed its C API), it opens an
> issue instead and keeps the kit as a 7-day run artifact
> (`gh run download <id> -n GhosttyKit`) so you can fix the code against it.
> Run it with `dry_run` to build + test without publishing anything.

## 2. Developer ID certificate (repo **Secrets**)

In **Keychain Access**, export your *Developer ID Application* certificate
(with its private key) as a `.p12`. Then:

```sh
base64 -i DeveloperID.p12 | pbcopy   # → DEVELOPER_ID_CERT_P12_BASE64
```

| Secret | Value |
|---|---|
| `DEVELOPER_ID_CERT_P12_BASE64` | base64 of the `.p12` |
| `DEVELOPER_ID_CERT_PASSWORD` | the password you set when exporting |

## 3. Notarization key (App Store Connect API — repo **Secrets**)

App Store Connect ▸ Users and Access ▸ **Integrations ▸ App Store Connect API**
▸ create a key with the **Developer** role. Download the `AuthKey_XXXXX.p8`
(one-time), and note the Key ID and Issuer ID.

```sh
base64 -i AuthKey_XXXXX.p8 | pbcopy   # → AC_API_KEY_P8_BASE64
```

| Secret | Value |
|---|---|
| `AC_API_KEY_ID` | the key's Key ID |
| `AC_API_ISSUER_ID` | the Issuer ID (top of the Keys page) |
| `AC_API_KEY_P8_BASE64` | base64 of the `.p8` |

## 4. Release

```sh
git tag v0.1.0 && git push origin v0.1.0
```

The workflow signs, notarizes, staples, builds `Vesta.dmg`, and publishes a
release. The DMG opens cleanly on any Mac (no "damaged" Gatekeeper warning).

## Local signed build

`make-app.sh` signs with Developer ID when `SIGN_ID` is set, else ad-hoc:

```sh
SIGN_ID="Developer ID Application: Your Name (TEAMID)" ./make-app.sh release
```

Entitlements live in `Vesta.entitlements` (Hardened Runtime; not sandboxed — a
terminal spawns arbitrary child processes).
