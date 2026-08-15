# AstrBot Android Scripts

This repository publishes the shared Linux installer used by AstrBot Android
clients. The APK contains only the immutable bootstrap and the Ed25519 public
key. The bootstrap downloads a release only after the signed manifest and the
payload checksum have both been verified.

## Repository layout

- `installer/astrbot-startup.sh`: shared runtime installer.
- `bootstrap/astrbot-installer-bootstrap.sh`: canonical immutable bootstrap.
- `bootstrap/installer-public.pem`: public key copied into APK clients.
- `scripts/build-release.sh`: creates a signed release payload.
- `scripts/verify-release.sh`: verifies a release before upload.
- `release/manifest.template.json`: reference for the generated manifest.

The runtime installer owns the core steps `base`, `uv`, `napcat`, and
`astrbot`. `opencode` is an optional compatibility step until the application
market is introduced. Its command-line identifier is intentionally stable so
it can become an application package without breaking existing clients.

## First-time key setup

Run these commands once on a trusted Linux, macOS, or Git Bash machine:

```bash
umask 077
mkdir -p keys
openssl genpkey -algorithm ED25519 -out keys/installer-private.pem
openssl pkey -in keys/installer-private.pem -pubout \
  -out bootstrap/installer-public.pem
```

`keys/installer-private.pem` is ignored by Git. Store an encrypted backup in a
password manager or another offline secret store. Anyone with this file can
publish a trusted installer update. Never add it to Git, a GitHub Release, an
APK, a chat message, or a user-visible download directory.

The bootstrap and public key must be copied exactly into the Bubble APK asset
and the Lua skin's `installer_bootstrap.lua` wrapper. The public key does not
need to be kept secret. The three bootstrap copies should be compared before
publishing either client.

If the private key is lost or suspected to be exposed, generate a new key pair
and ship a new APK with the replacement public key. Existing APKs can only
trust releases signed by their embedded public key.

## Publishing a release

1. Update `installer/astrbot-startup.sh` and choose a monotonic version, such
   as `0.1.1`.
2. Build and verify the release locally:

   ```bash
   bash scripts/build-release.sh 0.1.1 \
     keys/installer-private.pem bootstrap/installer-public.pem
   ```

3. Create the GitHub release tag `v0.1.1` in `MuFengDR/AstrBot-Android-Scripts`.
4. Upload these exact files from `dist/` as release assets:

   - `manifest.json`
   - `manifest.sig`
   - `astrbot-installer-v0.1.1.tar.gz`
   - `astrbot-installer-offline-v0.1.1.tar.gz`

`manifest.json`, `manifest.sig`, and the versioned installer archive must be
present on the latest release. The offline archive is optional for online
updates but is used by the client import function.

## Client commands

The immutable bootstrap supports these commands inside the Linux container:

```bash
bash /root/astrbot-installer-bootstrap.sh --check
bash /root/astrbot-installer-bootstrap.sh --update
bash /root/astrbot-installer-bootstrap.sh --import /root/offline-package.tar.gz
bash /root/astrbot-installer-bootstrap.sh --run --step napcat
```

`--check` verifies the signed remote manifest without replacing the current installer.
`--update` verifies and atomically installs it. `--import` applies the same
verification rules to an offline package.

## Future application market

The future market will use signed application metadata and application-owned
install, launch, and optional WebUI scripts. Core runtime steps remain in this
repository. Official applications, reviewed external applications, unreviewed
Git sources, and local applications can all expose the same card contract
without changing the bootstrap protocol.
# AstrBot-Android-Scripts
