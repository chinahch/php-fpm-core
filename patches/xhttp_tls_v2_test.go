package xray

import (
	"testing"

	"github.com/cedar2025/xboard-node/internal/kernel"
	"github.com/cedar2025/xboard-node/internal/model"
)

func TestXHTTPWithoutCertUsesPlaintext(t *testing.T) {
	nc := &model.NodeSpec{
		Protocol: "vless",
		Network:  "xhttp",
		TLS:      1,
		NetworkSettings: map[string]any{
			"path": "/",
			"mode": "packet-up",
			"alpn": "h2",
		},
	}

	base := M{}
	applyStreamSettings(base, nc, kernel.TLSCert{})

	ss := base["streamSettings"].(M)

	if ss["security"] == "tls" {
		t.Fatal("XHTTP without certificate must not enable backend TLS")
	}

	if ss["network"] != "xhttp" {
		t.Fatalf("unexpected network: %v", ss["network"])
	}
}

func TestXHTTPWithCertUsesTLSAndH2(t *testing.T) {
	nc := &model.NodeSpec{
		Protocol: "vless",
		Network:  "xhttp",
		TLS:      1,
		NetworkSettings: map[string]any{
			"path": "/",
			"mode": "packet-up",
			"alpn": "h2",
		},
	}

	cert := kernel.TLSCert{
		CertPEM: []byte("CERT"),
		KeyPEM:  []byte("KEY"),
	}

	base := M{}
	applyStreamSettings(base, nc, cert)

	ss := base["streamSettings"].(M)

	if ss["security"] != "tls" {
		t.Fatal("XHTTP with certificate must enable TLS")
	}

	tlsSettings := ss["tlsSettings"].(M)
	alpn := tlsSettings["alpn"].([]string)

	if len(alpn) != 1 || alpn[0] != "h2" {
		t.Fatalf("unexpected ALPN: %v", alpn)
	}
}
