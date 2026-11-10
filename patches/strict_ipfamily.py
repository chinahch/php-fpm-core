#!/usr/bin/env python3
"""Strengthen the native dual-IP-family patch in the pinned XBoard-Node source.

Must run AFTER the original XHTTP/TLS and v1 native ip_family source patches.
Strict address-family modes now reject opposite-family IP literals that
could have been pre-resolved by the client.
"""
from pathlib import Path


def replace_appended_function(path, marker, code):
    p = Path(path)
    src = p.read_text()
    if src.count(marker) != 1:
        raise SystemExit(f"{path}: cannot find unique v1 patch function marker")
    before, after = src.split(marker, 1)
    if "func applyMachineIPFamily" not in after:
        raise SystemExit(f"{path}: v1 function missing")
    # The v1 workflow always appends this helper at EOF.
    if "func " in after.split("func applyMachineIPFamily", 1)[1]:
        raise SystemExit(f"{path}: unexpected functions after old helper")
    p.write_text(before + code)


replace_appended_function(
    "internal/kernel/singbox/config.go",
    "// applyMachineIPFamily sets an address-family preference for DNS",
    """// applyMachineIPFamily keeps fallbacks for prefer modes and rejects
// already resolved opposite-family destinations in strict-only modes.
func applyMachineIPFamily(cfg M, kcfg config.KernelConfig) {
    strategy := kcfg.IPFamily["singbox"]
    switch strategy {
    case "prefer_ipv6", "prefer_ipv4", "ipv6_only", "ipv4_only":
    default:
        return
    }
    route, ok := cfg["route"].(M)
    if !ok { return }
    newRules := []M{}
    switch strategy {
    case "ipv4_only":
        newRules = append(newRules, M{"ip_version": 6, "action": "reject"})
    case "ipv6_only":
        newRules = append(newRules, M{"ip_version": 4, "action": "reject"})
    }
    newRules = append(newRules, M{"action": "resolve", "strategy": strategy})
    switch rules := route["rules"].(type) {
    case []M:
        route["rules"] = append(newRules, rules...)
    case []any:
        prefix := make([]any, 0, len(newRules)+len(rules))
        for _, r := range newRules { prefix = append(prefix, r) }
        route["rules"] = append(prefix, rules...)
    default:
        route["rules"] = newRules
    }
    nlog.Core().Info("singbox: applied ip family", "mode", strategy, "strict", len(newRules) > 1)
}
""",
)

replace_appended_function(
    "internal/kernel/xray/config.go",
    "// applyMachineIPFamily sets the address-family strategy on the",
    """// applyMachineIPFamily applies resolution strategies to freedom outbounds.
// Strict modes additionally reject already-resolved opposite-family IPs,
// which sockopt.domainStrategy alone cannot prevent.
func applyMachineIPFamily(cfg M, kcfg config.KernelConfig) {
    mode := kcfg.IPFamily["xray"]
    strategies := map[string]string{
        "prefer_ipv6": "UseIPv6v4",
        "prefer_ipv4": "UseIPv4v6",
        "ipv6_only": "ForceIPv6",
        "ipv4_only": "ForceIPv4",
    }
    strategy, ok := strategies[mode]
    if !ok { return }
    outbounds, ok := cfg["outbounds"].([]M)
    if !ok { nlog.Core().Error("xray: cannot apply ip family: outbounds missing"); return }
    matched := 0
    for _, outbound := range outbounds {
        if outbound["protocol"] != "freedom" { continue }
        stream, ok := outbound["streamSettings"].(M)
        if !ok { stream = M{}; outbound["streamSettings"] = stream }
        sockopt, ok := stream["sockopt"].(M)
        if !ok { sockopt = M{}; stream["sockopt"] = sockopt }
        sockopt["domainStrategy"] = strategy
        matched++
    }
    nlog.Core().Info("xray: applied ip family", "mode", mode,
        "domain_strategy", strategy, "freedom_outbounds", matched)
    if mode != "ipv4_only" && mode != "ipv6_only" { return }
    if matched == 0 { nlog.Core().Error("xray: strict ip family has no freedom outbound"); return }

    // A separate guaranteed blackhole, independent of panel "block" rules.
    const denyTag = "__xboard_ipfamily_deny"
    for _, outbound := range outbounds {
        if outbound["tag"] == denyTag {
            nlog.Core().Error("xray: reserved ip family deny tag already in use")
            return
        }
    }
    cidr := "::/0"
    if mode == "ipv6_only" { cidr = "0.0.0.0/0" }
    routing, ok := cfg["routing"].(M)
    if !ok { nlog.Core().Error("xray: strict ip family routing missing"); return }
    guard := M{"type": "field", "ip": []string{cidr}, "outboundTag": denyTag}
    switch rules := routing["rules"].(type) {
    case []M:
        routing["rules"] = append([]M{guard}, rules...)
    case []any:
        routing["rules"] = append([]any{guard}, rules...)
    default:
        routing["rules"] = []M{guard}
    }
    cfg["outbounds"] = append(outbounds, M{"protocol": "blackhole", "tag": denyTag})
    nlog.Core().Info("xray: strict ip family guard applied", "mode", mode, "blocked_cidr", cidr)
}
""",
)

Path("internal/kernel/xray/ipfamily_native_test.go").write_text("""package xray

import (
    "testing"
    "github.com/cedar2025/xboard-node/internal/config"
)
func TestNativeIPFamily(t *testing.T) {
    tests := []struct {mode, strategy, cidr string}{
        {"prefer_ipv4", "UseIPv4v6", ""},
        {"prefer_ipv6", "UseIPv6v4", ""},
        {"ipv4_only", "ForceIPv4", "::/0"},
        {"ipv6_only", "ForceIPv6", "0.0.0.0/0"},
    }
    for _, tt := range tests {
        t.Run(tt.mode, func(t *testing.T) {
            cfg := M{
                "outbounds": []M{{"tag":"direct","protocol":"freedom"}, {"tag":"block","protocol":"blackhole"}},
                "routing": M{"rules": []M{{"type":"field","domain":[]string{"domain:example.com"},"outboundTag":"direct"}}},
            }
            applyMachineIPFamily(cfg, config.KernelConfig{IPFamily:map[string]string{"xray":tt.mode}})
            out := cfg["outbounds"].([]M)
            actual := out[0]["streamSettings"].(M)["sockopt"].(M)["domainStrategy"]
            if actual != tt.strategy { t.Fatalf("strategy=%v, want %s", actual, tt.strategy) }
            rules := cfg["routing"].(M)["rules"].([]M)
            if tt.cidr == "" {
                if len(rules) != 1 || len(out) != 2 { t.Fatal("prefer must not block fallback") }
                return
            }
            if len(rules) != 2 || len(out) != 3 { t.Fatal("strict: deny routing missing") }
            if got := rules[0]["ip"].([]string)[0]; got != tt.cidr { t.Fatalf("deny CIDR=%s want %s",got,tt.cidr) }
            if rules[0]["outboundTag"] != "__xboard_ipfamily_deny" { t.Fatal("wrong deny tag") }
            if out[2]["protocol"] != "blackhole" { t.Fatal("deny outbound not blackhole") }
        })
    }
}
""")

Path("internal/kernel/singbox/ipfamily_native_test.go").write_text("""package singbox

import (
    "testing"
    "github.com/cedar2025/xboard-node/internal/config"
)
func TestNativeIPFamily(t *testing.T) {
    tests := []struct {mode string; denied int}{
        {"prefer_ipv4",0},{"prefer_ipv6",0},{"ipv4_only",6},{"ipv6_only",4},
    }
    for _,tt := range tests {
        t.Run(tt.mode,func(t *testing.T){
            cfg := M{"route":M{"rules":[]M{{"action":"route","outbound":"direct"}}}}
            applyMachineIPFamily(cfg,config.KernelConfig{IPFamily:map[string]string{"singbox":tt.mode}})
            rules := cfg["route"].(M)["rules"].([]M)
            if tt.denied == 0 {
                if len(rules)!=2 || rules[0]["action"]!="resolve" {t.Fatal("bad prefer mode")}
                return
            }
            if len(rules)!=3 || rules[0]["ip_version"]!=tt.denied || rules[0]["action"]!="reject" {
                t.Fatal("strict mode does not reject opposite-family destination")
            }
            if rules[1]["strategy"]!=tt.mode {t.Fatal("wrong DNS mode")}
        })
    }
}
""")
print("strict IP family patch complete")
