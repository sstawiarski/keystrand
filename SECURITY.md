# Security policy

<!-- replace: turn on private vulnerability reporting in the repository's
Settings > Code security before publishing. The "Report a vulnerability"
button below only appears once it is on. -->

## Supported versions

Security fixes go to `main` and the next tagged release. Keystrand has no
prebuilt binary, so you must build it from source.

The project supports these versions:

| Version | Supported |
| --- | --- |
| Latest tagged release | Yes |
| `main` | Yes |
| Older releases | No |

## Report a vulnerability

Do not include security details in a public issue, discussion, or pull request.
Remove real passwords, keys, hostnames, and data before you send a report.

To report a vulnerability privately through GitHub:

1. Open the repository's **Security** tab.
2. Choose **Report a vulnerability**.
3. Complete the form.
4. Submit the report.

Only you and the maintainer can read the report. If the button is missing,
open an issue to request a private contact. Do not include vulnerability details.

## Report contents

Include the following information:

- The Keystrand version and build. Choose **Help > Copy System Info** or
  open **About Keystrand**.
- Your macOS version and build method, such as `scripts/install.sh` or Xcode.
- The server type, version, and relevant connection settings. Examples include
  Redis or Valkey, standalone or cluster, Sentinel, SSH tunnels, and TLS.
- Steps to reproduce the problem or a proof of concept. Explain what an
  attacker gains.
- A suggested fix, if you have one.

## Response targets

One maintainer works on Keystrand in their spare time. The maintainer aims
to meet these response targets but cannot promise them:

- Acknowledge the report within 7 days.
- Assess the report and its scope within 14 days.
- Provide a fix or a dated plan within 90 days of a confirmed report.

The maintainer posts progress in the advisory. After the fix ships, the
maintainer publishes the advisory with credit to you unless you request
anonymity. Keep the vulnerability private until publication.

## Scope

The app, code, and scripts in this repository are in scope. The following
features handle sensitive data or run code:

- **Connection scripts.** A database can store pre-connection and
  post-disconnect shell scripts. Keystrand runs them with your login shell
  (`$SHELL -lc`, or `/bin/sh`) and your account's permissions. When you import
  a connection file, Keystrand removes its scripts and shows them for review
  before you choose to keep them. A method that runs a script without your
  authorship or review is in scope.
- **Connection links.** A `keystrand://databases/connect` link can add a database
  and connect to it. Keystrand must ask for confirmation first. A link that
  adds, changes, or connects to a database without confirmation is in scope.
- **Secrets.** Keystrand stores passwords, SSH private keys and passphrases,
  and client certificate keys in macOS Keychain. It must not store these secrets
  as plain text in Application Support JSON files. Plain text secrets on disk
  are in scope, except in connection exports with **Include passwords** enabled.
  Those exports contain plain text secrets by design.
- **Network access.** Keystrand sends no telemetry. It connects to configured
  servers, a Redis Software cluster address you enter for discovery, and local
  listening ports on `127.0.0.1` during the first-run scan. Other outbound
  connections are in scope.

The following certificate behavior is intentional:

- Redis Software discovery accepts the cluster certificate without checking
  it because these clusters usually use self-signed certificates.
- SSH tunnels run `/usr/bin/ssh` with `StrictHostKeyChecking=accept-new`.
  The first connection to a new SSH host trusts its host key.
- If **Verify server certificate** is off, a database connection accepts any
  TLS certificate.

The following reports are out of scope:

- Problems in Redis, Valkey, or their modules. Report them to those projects.
- Attacks that require an already compromised Mac or user account.
- Persuading a user to enter a malicious script in database settings.

Read the [privacy policy](PRIVACY.md) for details about stored data and
network connections.
