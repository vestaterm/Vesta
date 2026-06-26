# Signing, notarizing & releasing Vesta

The GitHub Actions workflow `.github/workflows/release.yml` builds `Vesta.app`,
signs it with your **Developer ID**, **notarizes** it with Apple, staples the
ticket, packages a DMG, and attaches it to a GitHub Release. Tag a commit
`vX.Y.Z` (or run the workflow manually) to trigger it.

You must add a few secrets/variables first — Apple won't let CI sign as you
without them, and Vesta's two large build inputs are gitignored.

## 1. Build inputs (repo **Variables** — Settings ▸ Secrets and variables ▸ Actions ▸ Variables)

These are gitignored in the repo (the 536 MB xcframework and the vendored
ghostty themes), so CI downloads them:

| Variable | Value |
|---|---|
| `GHOSTTYKIT_URL` | URL to a **zip of `GhosttyKit.xcframework`**. Host it as an asset on a GitHub Release in this repo (or any reachable URL). |
| `GHOSTTY_RESOURCES_URL` | *(optional)* URL to a tar.gz/zip of ghostty's `Resources/ghostty` dir (the 463 themes). If omitted, named themes won't bundle. |

> Tip: `cd Frameworks && zip -r ghosttykit.zip GhosttyKit.xcframework`, then
> `gh release create build-deps ghosttykit.zip` and point `GHOSTTYKIT_URL` at it.

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
| `APPLE_TEAM_ID` | your 10-character Team ID (Apple Developer ▸ Membership) |

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
