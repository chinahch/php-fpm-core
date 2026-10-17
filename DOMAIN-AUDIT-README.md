# Xboard-Node Caddy: opt-in destination audit (sing-box)

A source-overlay patch for `cedar2025/Xboard-Node` commit `0a29338`, without
changing the existing production binary or your original release packages.

## Features

- On accepted sing-box TCP / UDP routed connections, records timestamp (UTC),
  numeric XBoard user ID, destination domain or IP, port, network, inbound tag,
  and optional node ID to local daily JSONL files.
- Logging is **off by default**. It does not inspect TLS payloads or record full
  HTTPS URLs, page paths, queries, passwords, or user source IPs.
- Events are queued asynchronously; a full queue drops audit events rather than
  delaying connections. This is **not** a guaranteed-complete record.
- Files are created `0600`, directories `0700`, automatically cleaned based on
  UTC day and configured retention. Use per-host access control and encrypted
  backups when appropriate. Logs are not sent to the XBoard panel automatically.
- Root-only command-line domain stats via `scripts/query_audit.py`.

## Build / source

The included `build-caddy-audit.yml` workflow checks out upstream commit `0a29338`, then copies
`audit-overlay/internal/domainaudit/` into source tree and runs
`scripts/patch_source.py src`. The patcher fails if upstream code layout differs.

Do not assume the binary is identical to your old custom build: original source
is missing, and compatibility testing is required before deployment.

## Opt-in configuration (only for a new tested binary)

After user notice/consent and authorization, add the following *environment
variables* to `/etc/caddy/credentials.env` (service has `EnvironmentFile=`):

```
XBOARD_AUDIT_ENABLED=1
XBOARD_AUDIT_DIR=/var/log/caddy/domain-audit
XBOARD_AUDIT_RETENTION_DAYS=7
XBOARD_AUDIT_NODE_ID=123
```

`XBOARD_AUDIT_NODE_ID` is optional; set it to the panel node ID if one ID applies
to this process. Multi-node/machine mode requires an instance-aware node ID
integration before relying on the node_id field.

**Never activate audit logging without notice and appropriate authorization.**
Changing environment variables requires a restart. Running `systemctl restart
caddy` can interrupt current client connections; schedule a maintenance window.
To disable collection again, set `XBOARD_AUDIT_ENABLED=0` and restart the
validated binary. Stopping collection does not automatically remove existing
logs; retention cleanup applies only while the logger is enabled.

## Query

As an authorized administrator on the node, e.g.:

```
python3 scripts/query_audit.py --user 123 --days 7 --top 20
python3 scripts/query_audit.py --user 123 --days 1 --show-events
```

Query script is supplied separately in this repository; it is not yet packaged
inside `caddyctl`. No XBoard web UI or database migration is included.

## Caveats

- Only new accepted connections after enabling are recorded; past history
  cannot be recreated.
- Sing-box target metadata is not guaranteed to contain a hostname for
  IP-only connections, ECH, or other protocols; then only the IP is logged.
- UDP associations can yield multiple actual destinations; this first version
  records the routed association's destination, not every UDP packet.
- No guarantee of exhaustive logging: queue overflow, process crashes, or disk
  errors may lose records. Observe `journalctl -u caddy` for dropped/error logs.
- File access is limited by operating-system permissions; no web authorization
  interface exists. Test all original traffic stats, throttling and device limits.