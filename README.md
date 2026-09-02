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
- `download.rabah.ai`: planned primary download source for the latest supported
  version only

## Security

Never download Rabah Companion from an unlisted third-party mirror. Release
assets are immutable; a corrected build receives a new version instead of
silently replacing an existing file.
