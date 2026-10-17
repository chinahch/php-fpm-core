// Package domainaudit logs only accepted proxy destinations when explicitly enabled.
// It does not store HTTP URLs, request payloads, source IPs, or user UUIDs.
package domainaudit

import (
    "bufio"
    "encoding/json"
    "fmt"
    "log"
    "net"
    "os"
    "path/filepath"
    "strconv"
    "strings"
    "sync"
    "sync/atomic"
    "time"
)

type Event struct {
    Time time.Time `json:"time"`
    UserID int `json:"user_id"`
    NodeID int `json:"node_id,omitempty"`
    Target string `json:"target"`
    TargetType string `json:"target_type"`
    Port uint16 `json:"port"`
    Network string `json:"network"`
    Inbound string `json:"inbound,omitempty"`
}

type Recorder struct {
    dir string
    retention int
    nodeID int
    events chan Event
    dropped atomic.Uint64
}

var (
    once sync.Once
    instance *Recorder
)

// Default returns nil when XBOARD_AUDIT_ENABLED is not explicitly set to 1.
func Default() *Recorder {
    once.Do(func() {
        if os.Getenv("XBOARD_AUDIT_ENABLED") != "1" {
            return
        }
        dir := os.Getenv("XBOARD_AUDIT_DIR")
        if dir == "" {
            dir = "/var/log/caddy/domain-audit"
        }
        days := 7
        if raw := os.Getenv("XBOARD_AUDIT_RETENTION_DAYS"); raw != "" {
            n, err := strconv.Atoi(raw)
            if err != nil || n < 1 || n > 365 {
                log.Print("domain audit disabled: retention must be 1..365 days")
                return
            }
            days = n
        }
        nodeID, _ := strconv.Atoi(os.Getenv("XBOARD_AUDIT_NODE_ID"))
        recorder, err := New(dir, days, nodeID)
        if err != nil {
            log.Printf("domain audit disabled: %v", err)
            return
        }
        instance = recorder
        log.Printf("domain audit enabled dir=%s retention_days=%d", dir, days)
    })
    return instance
}

func New(dir string, retentionDays, nodeID int) (*Recorder, error) {
    if dir == "" || retentionDays < 1 || retentionDays > 365 {
        return nil, fmt.Errorf("invalid audit directory or retention days")
    }
    if err := os.MkdirAll(dir, 0700); err != nil {
        return nil, fmt.Errorf("mkdir: %w", err)
    }
    // Reject insecure directories instead of exposing browsing records.
    info, err := os.Stat(dir)
    if err != nil { return nil, err }
    if info.Mode().Perm() & 0077 != 0 {
        return nil, fmt.Errorf("audit directory must be private (chmod 700): %s", dir)
    }
    recorder := &Recorder{
        dir: dir, retention: retentionDays, nodeID: nodeID,
        events: make(chan Event, 4096),
    }
    go recorder.run()
    return recorder, nil
}

// Record never blocks a routed connection. Overflow drops an audit entry,
// not the user's connection. The dropped total is reported once per minute.
func (r *Recorder) Record(e Event) {
    if r == nil || e.UserID <= 0 { return }
    target := strings.ToLower(strings.TrimSuffix(strings.TrimSpace(e.Target), "."))
    if target == "" || len(target) > 253 || strings.ContainsAny(target, " \t\r\n/\\?#@") { return }
    if ip := net.ParseIP(target); ip != nil {
        e.TargetType = "ip"
        target = ip.String()
    } else {
        e.TargetType = "domain"
    }
    if e.Network != "tcp" && e.Network != "udp" { return }
    e.Target = target
    if e.Time.IsZero() { e.Time = time.Now().UTC() }
    e.NodeID = r.nodeID
    select {
    case r.events <- e:
    default:
        r.dropped.Add(1)
    }
}

func (r *Recorder) run() {
    var file *os.File
    var writer *bufio.Writer
    currentDay := ""
    flush := time.NewTicker(time.Second)
    cleanup := time.NewTicker(24 * time.Hour)
    report := time.NewTicker(time.Minute)
    defer flush.Stop()
    defer cleanup.Stop()
    defer report.Stop()
    defer func() {
        if writer != nil { _ = writer.Flush() }
        if file != nil { _ = file.Close() }
    }()
    r.cleanup(time.Now().UTC())
    var lastError time.Time
    reportError := func(err error) {
        if time.Since(lastError) >= 30 * time.Second {
            log.Printf("domain audit write error: %v", err)
            lastError = time.Now()
        }
    }
    for {
        select {
        case e := <-r.events:
            day := e.Time.UTC().Format("2006-01-02")
            if day != currentDay {
                if writer != nil { _ = writer.Flush(); writer = nil }
                if file != nil { _ = file.Close(); file = nil }
                currentDay = day
                path := filepath.Join(r.dir, "audit-" + day + ".jsonl")
                f, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0600)
                if err != nil { reportError(err); currentDay = ""; continue }
                if err := f.Chmod(0600); err != nil {
                    _ = f.Close()
                    reportError(err)
                    currentDay = ""
                    continue
                }
                file = f
                writer = bufio.NewWriterSize(file, 64 * 1024)
            }
            if writer == nil { continue }
            b, err := json.Marshal(e)
            if err != nil { continue }
            if _, err := writer.Write(append(b, '\n')); err != nil { reportError(err) }
        case <-flush.C:
            if writer != nil {
                if err := writer.Flush(); err != nil { reportError(err) }
            }
        case <-cleanup.C:
            r.cleanup(time.Now().UTC())
        case <-report.C:
            if n := r.dropped.Swap(0); n > 0 {
                log.Printf("domain audit dropped_events_last_minute=%d", n)
            }
        }
    }
}

func (r *Recorder) cleanup(now time.Time) {
    entries, err := os.ReadDir(r.dir)
    if err != nil {
        log.Printf("domain audit cleanup: %v", err)
        return
    }
    cutoff := now.AddDate(0, 0, -(r.retention - 1)).Format("2006-01-02")
    for _, entry := range entries {
        name := entry.Name()
        if entry.IsDir() || len(name) != len("audit-2006-01-02.jsonl") ||
           !strings.HasPrefix(name, "audit-") || !strings.HasSuffix(name, ".jsonl") {
            continue
        }
        day := strings.TrimSuffix(strings.TrimPrefix(name, "audit-"), ".jsonl")
        parsed, err := time.Parse("2006-01-02", day)
        if err != nil || parsed.Format("2006-01-02") != day || day >= cutoff { continue }
        if err := os.Remove(filepath.Join(r.dir, name)); err != nil {
            log.Printf("domain audit cleanup: %v", err)
        }
    }
}
