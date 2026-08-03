package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"math/big"
	"testing"
	"time"
)

func TestValidateCertificatePair(t *testing.T) {
	now := time.Now().UTC()
	certificatePEM, keyPEM := testCertificate(t, now.Add(-time.Hour), now.Add(24*time.Hour))
	certificate, err := validateCertificatePair(certificatePEM, keyPEM, now)
	if err != nil {
		t.Fatalf("valid pair rejected: %v", err)
	}
	if certificate.Subject.CommonName != "manager.test" {
		t.Fatalf("unexpected common name: %s", certificate.Subject.CommonName)
	}
}

func TestValidateCertificatePairRejectsMismatch(t *testing.T) {
	now := time.Now().UTC()
	certificatePEM, _ := testCertificate(t, now.Add(-time.Hour), now.Add(24*time.Hour))
	_, anotherKey := testCertificate(t, now.Add(-time.Hour), now.Add(24*time.Hour))
	if _, err := validateCertificatePair(certificatePEM, anotherKey, now); err == nil {
		t.Fatal("mismatched key was accepted")
	}
}

func TestValidateCertificatePairRejectsExpired(t *testing.T) {
	now := time.Now().UTC()
	certificatePEM, keyPEM := testCertificate(t, now.Add(-48*time.Hour), now.Add(-time.Hour))
	if _, err := validateCertificatePair(certificatePEM, keyPEM, now); err == nil {
		t.Fatal("expired certificate was accepted")
	}
}

func testCertificate(t *testing.T, notBefore, notAfter time.Time) ([]byte, []byte) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	template := &x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject:      pkix.Name{CommonName: "manager.test"},
		DNSNames:     []string{"manager.test"},
		NotBefore:    notBefore,
		NotAfter:     notAfter,
		KeyUsage:     x509.KeyUsageDigitalSignature,
	}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	keyDER, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	return pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}),
		pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: keyDER})
}
