package domainaudit

import (
  "os"
  "path/filepath"
  "strings"
  "testing"
  "time"
)

func TestRecordAndPermissions(t *testing.T) {
  dir := filepath.Join(t.TempDir(), "audit")
  r, err := New(dir, 7, 4)
  if err != nil { t.Fatal(err) }
  r.Record(Event{UserID:12, Target:"ExAmPle.COM.", Port:443, Network:"tcp"})
  name := filepath.Join(dir,"audit-"+time.Now().UTC().Format("2006-01-02")+".jsonl")
  deadline := time.Now().Add(3*time.Second)
  for time.Now().Before(deadline) {
    data, err := os.ReadFile(name)
    if err==nil && len(data)>0 {
      s:=string(data)
      if !strings.Contains(s,`"user_id":12`) || !strings.Contains(s,`"target":"example.com"`) || !strings.Contains(s,`"node_id":4`) { t.Fatalf("unexpected audit: %s",s) }
      fi,err:=os.Stat(name)
      if err != nil || fi.Mode().Perm()!=0600 { t.Fatalf("bad file permission: %v %v",fi,err) }
      return
    }
    time.Sleep(100*time.Millisecond)
  }
  t.Fatal("event not flushed")
}

func TestCleanupAndSensitiveInput(t *testing.T) {
  dir:=filepath.Join(t.TempDir(), "audit")
  r,err:=New(dir,7,0)
  if err!=nil { t.Fatal(err) }
  old:=filepath.Join(dir,"audit-2020-01-01.jsonl")
  keep:=filepath.Join(dir,"other.txt")
  _=os.WriteFile(old,[]byte("old"),0600)
  _=os.WriteFile(keep,[]byte("keep"),0600)
  r.cleanup(time.Now().UTC())
  if _,err:=os.Stat(old); !os.IsNotExist(err) { t.Fatal("old audit log kept") }
  if _,err:=os.Stat(keep); err!=nil { t.Fatal("unrelated file removed") }
  r.Record(Event{UserID:12,Target:"example.org/page?token=sensitive",Network:"tcp"})
  if len(r.events)!=0 { t.Fatal("sensitive target entered queue") }
}

// TestRejectInsecureDirectory makes sure the security guard stays active.
func TestRejectInsecureDirectory(t *testing.T) {
    dir := filepath.Join(t.TempDir(), "public-audit")
    if err := os.Mkdir(dir, 0755); err != nil {
        t.Fatal(err)
    }
    if err := os.Chmod(dir, 0755); err != nil {
        t.Fatal(err)
    }
    if _, err := New(dir, 7, 0); err == nil {
        t.Fatal("audit must reject a directory accessible by other users")
    }
}
