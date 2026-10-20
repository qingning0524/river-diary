package config

import (
	"encoding/base64"
	"strings"
	"testing"
)

func testProductionEnv(t *testing.T) {
	t.Helper()
	t.Setenv("APP_ENV", "production")
	t.Setenv("DATABASE_URL", "postgres://flowriver:secret@127.0.0.1:5432/flowriver?sslmode=disable")
	t.Setenv("LISTEN_ADDR", "127.0.0.1:8080")
	for index, name := range []string{"AUTH_HMAC_KEY", "OUTBOX_ENCRYPTION_KEY", "IDEMPOTENCY_ENCRYPTION_KEY", "APPLE_TOKEN_ENCRYPTION_KEY", "SECURITY_JOURNAL_SIGNING_KEY"} {
		key := make([]byte, 32)
		key[0] = byte(index + 1)
		t.Setenv(name, base64.StdEncoding.EncodeToString(key))
	}
	t.Setenv("TERMS_VERSION", "terms-2")
	t.Setenv("PRIVACY_VERSION", "privacy-2")
	t.Setenv("EMAIL_MODE", "smtp")
	t.Setenv("SMTP_ADDR", "smtp.example.org:465")
	t.Setenv("SMTP_TLS_MODE", "implicit")
	t.Setenv("SMTP_FROM", "account@mail.flowriver.xyz")
	t.Setenv("APPLE_ENABLED", "true")
	t.Setenv("APPLE_TEAM_ID", "TEAM123456")
	t.Setenv("APPLE_KEY_ID", "KEY1234567")
	t.Setenv("APPLE_PRIVATE_KEY_FILE", "/etc/flowriver/apple.p8")
	t.Setenv("APPLE_CLIENT_IDS", "studio.riverdiary.ios,studio.riverdiary.mac")
	t.Setenv("SECURITY_JOURNAL_ENDPOINT", "https://journal.example.net")
	t.Setenv("SECURITY_JOURNAL_TOKEN", "test-only")
}

func TestProductionRequiresAllAuthenticationAndJournalProviders(t *testing.T) {
	t.Run("missing Apple config fails closed", func(t *testing.T) {
		testProductionEnv(t)
		t.Setenv("APPLE_ENABLED", "false")
		if _, err := Load(); err == nil || !strings.Contains(err.Error(), "Apple auth") {
			t.Fatalf("Load() error=%v", err)
		}
	})
	t.Run("local same-host database is accepted", func(t *testing.T) {
		testProductionEnv(t)
		if _, err := Load(); err != nil {
			t.Fatalf("Load() error=%v", err)
		}
	})
	t.Run("remote database is rejected", func(t *testing.T) {
		testProductionEnv(t)
		t.Setenv("DATABASE_URL", "postgres://flowriver:secret@198.51.100.10:5432/flowriver")
		if _, err := Load(); err == nil || !strings.Contains(err.Error(), "local address") {
			t.Fatalf("Load() error=%v", err)
		}
	})
	t.Run("console mail is rejected", func(t *testing.T) {
		testProductionEnv(t)
		t.Setenv("EMAIL_MODE", "console")
		if _, err := Load(); err == nil || !strings.Contains(err.Error(), "EMAIL_MODE=smtp") {
			t.Fatalf("Load() error=%v", err)
		}
	})
	t.Run("non-HTTPS security journal is rejected", func(t *testing.T) {
		testProductionEnv(t)
		t.Setenv("SECURITY_JOURNAL_ENDPOINT", "http://journal.example.net")
		if _, err := Load(); err == nil || !strings.Contains(err.Error(), "must use HTTPS") {
			t.Fatalf("Load() error=%v", err)
		}
	})
}
