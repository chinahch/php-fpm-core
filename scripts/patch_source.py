#!/usr/bin/env python3
"""Apply the domain-audit hook to the pinned upstream Xboard-Node source."""
import pathlib
import sys
if len(sys.argv) != 2:
    sys.exit('usage: patch_source.py /path/to/Xboard-Node')
p = pathlib.Path(sys.argv[1]) / 'internal/kernel/singbox/conntracker.go'
s = p.read_text()
if 'internal/domainaudit' in s:
    sys.exit('source already patched')
def replace_once(old, new):
    global s
    matches = s.count(old)
    if matches != 1:
        sys.exit(f'upstream source changed: expected one match, got {matches}: {old[:80]!r}')
    s = s.replace(old, new, 1)
replace_once('"github.com/cedar2025/xboard-node/internal/nlog"',
    '"github.com/cedar2025/xboard-node/internal/nlog"\n\t"github.com/cedar2025/xboard-node/internal/domainaudit"')
replace_once('deviceLimitFunc atomic.Pointer[func(uuid string) (int, bool)]',
    'deviceLimitFunc atomic.Pointer[func(uuid string) (int, bool)]\n\taudit *domainaudit.Recorder')
replace_once('globalDevices: make(map[int]map[string]bool),',
    'globalDevices: make(map[int]map[string]bool),\n\t\taudit: domainaudit.Default(),')
replace_once('\t// Register connection\n\tif us != nil {',
    '\tt.recordDestination(uid, metadata, "tcp")\n\n\t// Register connection\n\tif us != nil {')
replace_once('\tif us != nil {\n\t\tus.addConn(sourceIP)\n\t}\n\n\tconnID := t.nextID()',
    '\tt.recordDestination(uid, metadata, "udp")\n\n\tif us != nil {\n\t\tus.addConn(sourceIP)\n\t}\n\n\tconnID := t.nextID()')
insert = '''// recordDestination only records accepted connections and XBoard numeric user IDs.
func (t *ConnTracker) recordDestination(uid int, md adapter.InboundContext, network string) {
    if t.audit == nil || uid <= 0 { return }
    target := md.Domain
    if target == "" { target = md.Destination.Fqdn }
    if target == "" && md.Destination.Addr.IsValid() { target = md.Destination.Addr.String() }
    t.audit.Record(domainaudit.Event{
        UserID: uid,
        Target: target,
        Port: md.Destination.Port,
        Network: network,
        Inbound: md.Inbound,
    })
}

'''
replace_once('// checkDeviceGate rejects connections exceeding device limit.',
             insert + '// checkDeviceGate rejects connections exceeding device limit.')
p.write_text(s)
print('Patched', p)
