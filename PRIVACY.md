# Privacy

Keystrand collects no personal or usage data. It provides none of the following:

- Telemetry, usage analytics, or crash reporting.
- Accounts, sign-in, or license checks.
- Cloud features, sync, or update checks.

Keystrand sends no app activity to the project or other recipients beyond
the [network connections](#network-connections) described in this policy.

## Network connections

Keystrand connects to these destinations:

- The Redis and Valkey servers you add, including configured SSH hosts and
  Sentinel nodes.
- The Redis Software cluster address you enter to discover databases.
- Listening ports on `127.0.0.1` during the first-run local scan.

**Help > Redis Command Reference** opens the redis.io command documentation in
your web browser. Keystrand does not load the page itself.

### First-run local scan

On first launch, if you have no saved databases, Keystrand scans your Mac for
Redis and Valkey servers. It uses `netstat` to list listening TCP ports.
It connects to each port on `127.0.0.1` and sends `PING`. If a port returns
`PONG`, Keystrand sends `INFO server`. It adds each detected standalone server
to your saved databases.

The scan runs once and connects only to your Mac. To disable it, set
`KEYSTRAND_DISABLE_AUTODISCOVERY=1` when you launch Keystrand:

```bash
KEYSTRAND_DISABLE_AUTODISCOVERY=1 /Applications/Keystrand.app/Contents/MacOS/Keystrand
```

Opening a database at launch with `--open` or `--open-id` also skips the scan.

## Where your data is stored

Keystrand stores databases, settings, history, analysis reports, and Profiler
logs as plain JSON in `~/Library/Application Support/Keystrand`. If you set
`$KEYSTRAND_DATA_DIR`, Keystrand uses that directory instead.

Keystrand stores passwords, SSH private keys and passphrases, and client
certificate keys in macOS Keychain under `Keystrand`. It never stores them in
the app's JSON files. The README lists the [individual data files](README.md#where-data-is-stored).

To remove all stored data:

1. Quit Keystrand.
2. Delete its data directory.
3. Delete the `Keystrand` items in Keychain Access.

## Copy System Info

Choose **Help > Copy System Info** to copy diagnostics to the clipboard for
a bug report. The text uses this format:

````text
```
Keystrand diagnostics
App version:   1.0.0
Build:         1
OS:            macOS 26.6.0 (arm64)
```
````

The diagnostics contain only the app version, build number, macOS version,
and CPU architecture. They contain no database names, hosts, keys, or settings.
Keystrand does not send the copied text anywhere.

## Connection export

Connection exports contain plain text secrets by default because **Include
passwords** starts enabled. Disable it to exclude secrets and connection scripts.
If you keep it enabled, store the exported file securely.

To save connections as a JSON file, choose **Export** in the Redis Databases
window or a database's context menu. The window shortcut is Shift-Command-E.
RedisInsight can also read the file.

The export includes these fields based on **Include passwords**:

| Field in the file | Secret | Option off | Option on |
| --- | --- | --- | --- |
| `id`, `name`, `host`, `port`, `db`, `username` | No | Yes | Yes |
| `connectionType`, `nodes` (cluster node hosts and ports) | No | Yes | Yes |
| `tls`, `verifyServerCert`, `tlsServername` | No | Yes | Yes |
| `tags`, `environment`, `modules`, `provider`, `nameFromProvider` | No | Yes | Yes |
| `compressor`, `keyNameFormat`, `connectionFamily`, `forceStandalone`, `timeout`, `lastConnection` | No | Yes | Yes |
| `sentinelMaster.name`, `sentinelMaster.username` | No | Yes | Yes |
| `sshOptions.host`, `sshOptions.port`, `sshOptions.username`, `ssh` | No | Yes | Yes |
| `caCert` (name and certificate) | No | Yes | Yes |
| `clientCert` (name and certificate) | No | Yes | Yes |
| `password` (database password) | Yes | No | Yes |
| `sentinelMaster.password` | Yes | No | Yes |
| `sshOptions.password` | Yes | No | Yes |
| `sshOptions.privateKey` | Yes | No | Yes |
| `sshOptions.passphrase` (SSH key passphrase) | Yes | No | Yes |
| `clientCert.key` (client certificate private key) | Yes | No | Yes |
| `preConnectScript`, `postDisconnectScript` | Treated as a secret | No | Yes |

**Include passwords** also controls SSH passphrases, client certificate keys,
and connection scripts. Certificates are public data, so exports always
include them.

When you import connections, Keystrand removes scripts and shows them for
review. It keeps the scripts only if you choose to keep them.

## Questions

Open an issue for privacy questions. Report security problems privately through
the process in the [security policy](SECURITY.md).
