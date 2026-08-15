# Application Market Compatibility Contract

This document reserves the boundary for the future application market. It does
not implement a market UI yet.

## Core versus applications

The following are core runtime steps and are always delivered by the signed
shared installer:

- `base`
- `uv`
- `napcat`
- `astrbot`

All other tools are applications. `opencode` is currently callable through
`--step opencode` as a transition path. Its stable identifier allows its
implementation to move into a market package later while old clients keep
working.

## Application descriptor

Every application source will resolve to one signed descriptor before install.
The descriptor must include:

```json
{
  "format": "astrbot-android-app-v1",
  "id": "lowercase-stable-id",
  "name": "Visible application name",
  "version": "1.0.0",
  "author": "Author name or URL",
  "icon": "optional local or HTTPS icon",
  "readme": "README.md",
  "install": "scripts/install.sh",
  "start": "scripts/start.sh",
  "webui": { "enabled": false, "open": "scripts/open-webui.sh" },
  "status": "scripts/status.sh",
  "actions": []
}
```

`status` prints card information as plain text. `actions` will declare the
author-defined menu actions, including either terminal commands or WebUI
openers. The host owns button rendering, confirmation, logging, process keys,
and permission prompts; application scripts only supply behavior.

## Source classes

1. Built-in applications have descriptors and scripts in the official
   installer release.
2. Reviewed applications have official registry metadata but download their
   signed source package from the author repository.
3. Compatible third-party applications are installed from a user-provided Git
   URL after displaying source and trust information.
4. Local applications are created on device, use the same descriptor, and can
   be exported as a package containing its descriptor and scripts.

Only class 4 supports the user-facing share action. Classes 1-3 are installed
from their authoritative source and do not advertise a share action.

## Trust and update rules

The official registry and built-in packages are verified with the immutable
installer public key. Reviewed external packages use the signing key declared
by their approved registry entry. Unreviewed Git and local applications are
explicitly marked as user-trusted and are never silently updated. Local export
contains no device credentials, generated tokens, database files, or runtime
data.
