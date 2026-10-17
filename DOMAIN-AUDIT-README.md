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
## Alpine ARM64 / 128 MiB low-memory safety (experimental)

- An Alpine 3.24.1 `aarch64` container (128 MiB cgroup memory.max)
  experienced a segmentation fault after deploying an earlier ARM64 build,
  even though the same binary passed `caddy -v` in a test directory.
  **Root cause is not established**; OOM counters were zero at diagnosis.
- The original Caddy was restored successfully. Keep it running while
  investigating. The previous ARM64 release is **not production-validated**.
- New source reduces the audit event queue from 4096 to 512 and the file
  write buffer from 64 KiB to 8 KiB. These savings are modest and **do not
  prove the crash is fixed**.
- The installer now offers `--check-only` (no service changes) and refuses
  ARM64 replacement by default. A controlled ARM64 deployment requires the
  explicit `--experimental-arm64` flag and an out-of-band recovery console.
  It checks for a real, stable Caddy process (not just the OpenRC supervisor),
  and tries to restore the old program and environment on failure.
- For optional Go soft memory tuning in a test environment, specify
  `--go-memlimit 64MiB`. This is not a hard RSS limit and may be superseded
  by explicit runtime limits in `config.yml`.
- New builds publish to `caddy-audit-lowmem-rc-<run_number>`, separate
  from previously published and in-service versions.

### Safe offline check on Alpine ARM64

After building the release candidate in Actions, download the updated
`install-caddy-audit.sh`, then run:

```sh
sh /root/install-caddy-audit.sh --check-only \
  --package-url 'https://github.com/chinahch/php-fpm-core/releases/download/caddy-audit-lowmem-rc-RUN_NUMBER/caddy-linux-arm64v1.tar.gz'
```

Replace RUN_NUMBER with the successful GitHub Actions run number.
A successful `--check-only` **does not** verify service startup or proxy
compatibility. Do not use the experimental deployment switch on an active
128 MiB production node until equivalent workloads pass in a test container.
