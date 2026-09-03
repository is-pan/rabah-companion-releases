# Rabah Companion Releases

Official binary release archive for **Rabah Companion** on macOS and Windows.

The application source is maintained in a private repository. This public
repository contains release metadata and downloadable installer assets only.

## Current status

There is no generally supported public stable build yet. Existing releases are
historical internal-test builds preserved for traceability and are marked as
pre-releases.

Do not install a historical build unless you are reproducing an old test. Old
builds may contain known login, background-service, Codex integration, update,
or security limitations.

## Platforms

- Windows x64: NSIS setup executable (`*-setup.exe`)
- macOS Apple silicon: disk image (`*.dmg`), where an original disk image was
  retained

Some early releases are available only for Windows. Missing versions or
platforms were not reconstructed from installed applications.

## Integrity and signing

Each release includes a `SHA256SUMS` file. Verify the checksum before using an
installer.

Historical Windows installers are unsigned. Historical macOS builds use Apple
Development signing rather than Developer ID distribution signing and Apple
notarization. These signing states are not suitable for a general public
release.

A future stable release will require Windows Authenticode signing and macOS
Developer ID signing, hardened runtime, notarization, and stapling.

## Download policy

- GitHub Releases: permanent version archive and fallback download source
- `download.rabah.ai`: primary download source for the latest complete macOS +
  Windows version only

The fixed download paths are:

- `https://download.rabah.ai/latest/Rabah-Companion-Windows-x64-setup.exe`
- `https://download.rabah.ai/latest/Rabah-Companion-macOS-arm64.dmg`
- `https://download.rabah.ai/latest/SHA256SUMS.txt`
- `https://download.rabah.ai/latest.json`

Starting with `0.1.41`, installed applications check the signed Tauri updater
manifest at `https://download.rabah.ai/updater/latest.json`. Release assets must
also contain the Windows installer signature and the signed macOS app archive;
the R2 workflow rejects incomplete updater releases.

The `latest.json` manifest points at immutable, versioned R2 object URLs and
includes each installer's SHA-256 digest and byte size. GitHub Actions selects
the highest semantic version that has both platform installers and a checksum
file. This includes pre-releases while Rabah Companion remains in testing.

R2 retains only that selected version. Older installers remain available from
GitHub Releases.

## Security

Never download Rabah Companion from an unlisted third-party mirror. Release
assets are immutable; a corrected build receives a new version instead of
silently replacing an existing file.
