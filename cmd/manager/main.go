package main

import (
	"bytes"
	"context"
	"crypto"
	"crypto/ecdsa"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	maxPEMSize       = 2 << 20
	maxRequestSize   = 5 << 20
	defaultConfigDir = "/opt/__container"
)

type certificateInfo struct {
	Source          string   `json:"source"`
	UploadEnabled   bool     `json:"upload_enabled"`
	Subject         string   `json:"subject,omitempty"`
	Issuer          string   `json:"issuer,omitempty"`
	Names           []string `json:"names,omitempty"`
	NotBefore       string   `json:"not_before,omitempty"`
	NotAfter        string   `json:"not_after,omitempty"`
	DaysRemaining   int      `json:"days_remaining,omitempty"`
	SerialNumber    string   `json:"serial_number,omitempty"`
	FingerprintSHA  string   `json:"fingerprint_sha256,omitempty"`
	PersistencePath string   `json:"persistence_path,omitempty"`
	LockedReason    string   `json:"locked_reason,omitempty"`
	Error           string   `json:"error,omitempty"`
}

type manager struct {
	configDir    string
	configureBin string
	nginxBin     string
	mu           sync.Mutex
}

func main() {
	port, err := parsePort(os.Getenv("MANAGER_PORT"), 8788)
	if err != nil {
		log.Fatal(err)
	}
	configDir := os.Getenv("MANAGER_CONFIG_DIR")
	if configDir == "" {
		configDir = defaultConfigDir
	}
	configDir = filepath.Clean(configDir)
	if !filepath.IsAbs(configDir) || configDir == "/" {
		log.Fatal("MANAGER_CONFIG_DIR must be a safe absolute directory")
	}

	m := &manager{
		configDir:    configDir,
		configureBin: envOrDefault("MANAGER_CONFIGURE_BIN", "/etc/s6-overlay/scripts/configure-nginx"),
		nginxBin:     envOrDefault("MANAGER_NGINX_BIN", "/usr/sbin/nginx"),
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", m.health)
	mux.HandleFunc("/api/certificate", m.certificate)

	server := &http.Server{
		Addr:              net.JoinHostPort("127.0.0.1", strconv.Itoa(port)),
		Handler:           securityHeaders(mux),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       60 * time.Second,
		MaxHeaderBytes:    32 << 10,
	}
	log.Printf("[manager] Listening on %s; config=%s", server.Addr, configDir)
	if err := server.ListenAndServe(); !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
}

func parsePort(value string, fallback int) (int, error) {
	if value == "" {
		return fallback, nil
	}
	port, err := strconv.Atoi(value)
	if err != nil || port < 1 || port > 65535 {
		return 0, errors.New("MANAGER_PORT must be between 1 and 65535")
	}
	return port, nil
}

func envOrDefault(name, fallback string) string {
	if value := os.Getenv(name); value != "" {
		return value
	}
	return fallback
}

func securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		next.ServeHTTP(w, r)
	})
}

func (m *manager) health(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method not allowed"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

func (m *manager) certificate(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		writeJSON(w, http.StatusOK, m.currentCertificateInfo())
	case http.MethodPost:
		m.uploadCertificate(w, r)
	default:
		writeJSON(w, http.StatusMethodNotAllowed, map[string]string{"error": "method not allowed"})
	}
}

func (m *manager) uploadCertificate(w http.ResponseWriter, r *http.Request) {
	if r.Header.Get("X-Requested-With") != "docker-image-manager" {
		writeJSON(w, http.StatusForbidden, map[string]string{"error": "missing management request header"})
		return
	}
	if !sameOrigin(r) {
		writeJSON(w, http.StatusForbidden, map[string]string{"error": "cross-origin request rejected"})
		return
	}
	_, _, source, uploadEnabled, _ := m.certificatePaths()
	if !uploadEnabled {
		writeJSON(w, http.StatusConflict, map[string]string{"error": "certificate is controlled by " + source})
		return
	}

	r.Body = http.MaxBytesReader(w, r.Body, maxRequestSize)
	if err := r.ParseMultipartForm(1 << 20); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid certificate upload"})
		return
	}
	if r.MultipartForm != nil {
		defer r.MultipartForm.RemoveAll()
	}
	certificatePEM, err := readUpload(r, "certificate")
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
		return
	}
	privateKeyPEM, err := readUpload(r, "private_key")
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
		return
	}
	certificate, err := validateCertificatePair(certificatePEM, privateKeyPEM, time.Now())
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
		return
	}

	m.mu.Lock()
	defer m.mu.Unlock()
	if err := m.installCertificate(certificatePEM, privateKeyPEM, certificate); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, m.currentCertificateInfo())
}

func sameOrigin(r *http.Request) bool {
	origin := r.Header.Get("Origin")
	if origin == "" {
		return true
	}
	protocol := r.Header.Get("X-Forwarded-Proto")
	if protocol == "" {
		protocol = "https"
	}
	return origin == protocol+"://"+r.Host
}

func readUpload(r *http.Request, field string) ([]byte, error) {
	file, _, err := r.FormFile(field)
	if err != nil {
		return nil, fmt.Errorf("%s file is required", field)
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, maxPEMSize+1))
	if err != nil {
		return nil, fmt.Errorf("could not read %s", field)
	}
	if len(data) == 0 || len(data) > maxPEMSize {
		return nil, fmt.Errorf("%s must be between 1 byte and 2 MiB", field)
	}
	return data, nil
}

func validateCertificatePair(certificatePEM, privateKeyPEM []byte, now time.Time) (*x509.Certificate, error) {
	certificate, err := parseCertificate(certificatePEM)
	if err != nil {
		return nil, err
	}
	privateKey, err := parsePrivateKey(privateKeyPEM)
	if err != nil {
		return nil, err
	}
	publicKey, err := x509.MarshalPKIXPublicKey(privateKey.Public())
	if err != nil || !bytes.Equal(publicKey, certificate.RawSubjectPublicKeyInfo) {
		return nil, errors.New("certificate and private key do not match")
	}
	if now.Before(certificate.NotBefore) {
		return nil, errors.New("certificate is not valid yet")
	}
	if !now.Before(certificate.NotAfter) {
		return nil, errors.New("certificate has expired")
	}
	return certificate, nil
}

func parseCertificate(data []byte) (*x509.Certificate, error) {
	rest := data
	for {
		block, remaining := pem.Decode(rest)
		if block == nil {
			break
		}
		rest = remaining
		if block.Type != "CERTIFICATE" {
			continue
		}
		certificate, err := x509.ParseCertificate(block.Bytes)
		if err != nil {
			return nil, errors.New("certificate PEM is invalid")
		}
		return certificate, nil
	}
	return nil, errors.New("certificate PEM does not contain an X.509 certificate")
}

func parsePrivateKey(data []byte) (crypto.Signer, error) {
	block, rest := pem.Decode(data)
	if block == nil || len(bytes.TrimSpace(rest)) != 0 {
		return nil, errors.New("private key PEM is invalid")
	}
	if x509.IsEncryptedPEMBlock(block) {
		return nil, errors.New("encrypted private keys are not supported")
	}
	var key any
	var err error
	switch block.Type {
	case "RSA PRIVATE KEY":
		key, err = x509.ParsePKCS1PrivateKey(block.Bytes)
	case "EC PRIVATE KEY":
		key, err = x509.ParseECPrivateKey(block.Bytes)
	case "PRIVATE KEY":
		key, err = x509.ParsePKCS8PrivateKey(block.Bytes)
	default:
		return nil, errors.New("private key must be PKCS#1, EC, or PKCS#8 PEM")
	}
	if err != nil {
		return nil, errors.New("private key PEM is invalid")
	}
	signer, ok := key.(crypto.Signer)
	if !ok {
		return nil, errors.New("private key type is not supported")
	}
	switch signer.(type) {
	case *rsa.PrivateKey, *ecdsa.PrivateKey:
		return signer, nil
	default:
		return nil, errors.New("private key must use RSA or ECDSA")
	}
}

func (m *manager) certificatePaths() (certPath, keyPath, source string, uploadEnabled bool, lockedReason string) {
	environmentCert := os.Getenv("NGINX_TLS_CERT_FILE")
	environmentKey := os.Getenv("NGINX_TLS_KEY_FILE")
	if environmentCert != "" || environmentKey != "" {
		return environmentCert, environmentKey, "environment", false, "NGINX_TLS_CERT_FILE and NGINX_TLS_KEY_FILE"
	}
	mountedCert := "/etc/nginx/certs/tls.crt"
	mountedKey := "/etc/nginx/certs/tls.key"
	if fileExists(mountedCert) || fileExists(mountedKey) {
		return mountedCert, mountedKey, "mounted", false, "/etc/nginx/certs"
	}
	uploadedCert := filepath.Join(m.configDir, "tls", "current", "tls.crt")
	uploadedKey := filepath.Join(m.configDir, "tls", "current", "tls.key")
	if fileExists(uploadedCert) || fileExists(uploadedKey) {
		return uploadedCert, uploadedKey, "uploaded", true, ""
	}
	return "/run/nginx/default-certificate/tls.crt", "/run/nginx/default-certificate/tls.key", "generated", true, ""
}

func fileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

func (m *manager) currentCertificateInfo() certificateInfo {
	certPath, _, source, uploadEnabled, lockedReason := m.certificatePaths()
	info := certificateInfo{
		Source:          source,
		UploadEnabled:   uploadEnabled,
		PersistencePath: filepath.Join(m.configDir, "tls"),
		LockedReason:    lockedReason,
	}
	data, err := os.ReadFile(certPath)
	if err != nil {
		info.Error = "active certificate is not readable"
		return info
	}
	certificate, err := parseCertificate(data)
	if err != nil {
		info.Error = err.Error()
		return info
	}
	fingerprint := sha256.Sum256(certificate.Raw)
	names := append([]string{}, certificate.DNSNames...)
	for _, address := range certificate.IPAddresses {
		names = append(names, address.String())
	}
	if len(names) == 0 && certificate.Subject.CommonName != "" {
		names = append(names, certificate.Subject.CommonName)
	}
	info.Subject = certificate.Subject.String()
	info.Issuer = certificate.Issuer.String()
	info.Names = names
	info.NotBefore = certificate.NotBefore.UTC().Format(time.RFC3339)
	info.NotAfter = certificate.NotAfter.UTC().Format(time.RFC3339)
	info.DaysRemaining = int(time.Until(certificate.NotAfter).Hours() / 24)
	info.SerialNumber = certificate.SerialNumber.Text(16)
	info.FingerprintSHA = strings.ToUpper(hex.EncodeToString(fingerprint[:]))
	return info
}

func (m *manager) installCertificate(certificatePEM, privateKeyPEM []byte, certificate *x509.Certificate) error {
	tlsRoot := filepath.Join(m.configDir, "tls")
	versionsDir := filepath.Join(tlsRoot, "versions")
	if err := os.MkdirAll(versionsDir, 0o700); err != nil {
		return errors.New("could not create certificate storage")
	}
	_ = os.Chmod(tlsRoot, 0o700)
	_ = os.Chmod(versionsDir, 0o700)
	stagingDir, err := os.MkdirTemp(versionsDir, ".upload-")
	if err != nil {
		return errors.New("could not stage certificate")
	}
	defer os.RemoveAll(stagingDir)
	if err := writeFileSync(filepath.Join(stagingDir, "tls.crt"), certificatePEM, 0o644); err != nil {
		return errors.New("could not stage certificate")
	}
	if err := writeFileSync(filepath.Join(stagingDir, "tls.key"), privateKeyPEM, 0o600); err != nil {
		return errors.New("could not stage private key")
	}
	fingerprint := sha256.Sum256(certificate.Raw)
	versionName := fmt.Sprintf("%s-%x", time.Now().UTC().Format("20060102T150405.000000000Z"), fingerprint[:6])
	versionDir := filepath.Join(versionsDir, versionName)
	if err := os.Rename(stagingDir, versionDir); err != nil {
		return errors.New("could not store certificate version")
	}

	currentLink := filepath.Join(tlsRoot, "current")
	oldTarget, oldErr := os.Readlink(currentLink)
	hadOldTarget := oldErr == nil
	if oldErr != nil && !errors.Is(oldErr, os.ErrNotExist) {
		_ = os.RemoveAll(versionDir)
		return errors.New("certificate current path is not a managed link")
	}
	newTarget := filepath.Join("versions", versionName)
	if err := replaceSymlink(currentLink, newTarget); err != nil {
		_ = os.RemoveAll(versionDir)
		return errors.New("could not activate certificate")
	}

	if err := m.applyNginx(); err != nil {
		if hadOldTarget {
			_ = replaceSymlink(currentLink, oldTarget)
		} else {
			_ = os.Remove(currentLink)
		}
		rollbackErr := m.applyNginx()
		_ = os.RemoveAll(versionDir)
		if rollbackErr != nil {
			return fmt.Errorf("certificate activation failed and rollback needs attention: %v", err)
		}
		return fmt.Errorf("certificate activation failed; previous certificate restored: %v", err)
	}
	return nil
}

func writeFileSync(path string, data []byte, mode os.FileMode) error {
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, mode)
	if err != nil {
		return err
	}
	if _, err = file.Write(data); err == nil {
		err = file.Sync()
	}
	closeErr := file.Close()
	if err != nil {
		return err
	}
	return closeErr
}

func replaceSymlink(linkPath, target string) error {
	temporary := fmt.Sprintf("%s.%d.tmp", linkPath, os.Getpid())
	_ = os.Remove(temporary)
	if err := os.Symlink(target, temporary); err != nil {
		return err
	}
	if err := os.Rename(temporary, linkPath); err != nil {
		_ = os.Remove(temporary)
		return err
	}
	return nil
}

func (m *manager) applyNginx() error {
	if err := runCommand(m.configureBin); err != nil {
		return err
	}
	return runCommand(m.nginxBin, "-s", "reload", "-c", "/run/nginx/nginx.conf")
}

func runCommand(name string, arguments ...string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	output, err := exec.CommandContext(ctx, name, arguments...).CombinedOutput()
	if err == nil {
		return nil
	}
	message := strings.TrimSpace(string(output))
	if len(message) > 2048 {
		message = message[len(message)-2048:]
	}
	if message == "" {
		message = err.Error()
	}
	return errors.New(message)
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(value); err != nil {
		log.Printf("[manager] Could not write response: %v", err)
	}
}
