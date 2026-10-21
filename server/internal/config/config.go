package config

import (
	"bytes"
	"encoding/base64"
	"fmt"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

type Config struct {
	Environment          string
	AccountAuthMode      string
	ListenAddr           string
	AdminListenAddr      string
	AdminEnabled         bool
	AdminOrigin          string
	AdminAllowedNetworks []net.IPNet
	DatabaseURL          string

	AuthHMACKey             []byte
	OutboxEncryptionKey     []byte
	IdempotencyKey          []byte
	AppleTokenEncryptionKey []byte
	AdminTOTPEncryptionKey  []byte
	AdminAuditHMACKey       []byte

	TermsVersion   string
	PrivacyVersion string

	EmailMode    string
	SMTPAddr     string
	SMTPTLSMode  string
	SMTPUsername string
	SMTPPassword string
	SMTPFrom     string

	AppleEnabled        bool
	AppleTeamID         string
	AppleKeyID          string
	ApplePrivateKeyFile string
	AppleClientIDs      []string

	SecurityJournalEndpoint string
	SecurityJournalToken    string
	SecurityJournalKey      []byte
	SecurityJournalMode     string

	DownloadDir string

	OfficialAIBaseURL           string
	OfficialAIAPIKey            string
	OfficialAIModel             string
	OfficialAIMonthlyTokenLimit int64
}

func Load() (Config, error) {
	return load(false)
}

// LoadAdminOnly validates the production database and administrator console
// configuration while deliberately omitting the account-service dependencies.
// It is used only by the explicit `admin serve` command; normal startup always
// goes through Load and retains the full production checks.
func LoadAdminOnly() (Config, error) {
	c, err := load(true)
	if err != nil {
		return Config{}, err
	}
	if c.Environment != "production" {
		return Config{}, fmt.Errorf("admin-only mode requires APP_ENV=production")
	}
	if !c.AdminEnabled {
		return Config{}, fmt.Errorf("admin-only mode requires ADMIN_ENABLED=true")
	}
	return c, nil
}

func load(adminOnly bool) (Config, error) {
	c := Config{
		Environment:             env("APP_ENV", "development"),
		AccountAuthMode:         env("ACCOUNT_AUTH_MODE", "email_and_apple"),
		ListenAddr:              env("LISTEN_ADDR", "127.0.0.1:8080"),
		AdminListenAddr:         env("ADMIN_LISTEN_ADDR", "127.0.0.1:8081"),
		AdminEnabled:            strings.EqualFold(env("ADMIN_ENABLED", "false"), "true"),
		AdminOrigin:             env("ADMIN_ORIGIN", "http://127.0.0.1:8081"),
		AdminAllowedNetworks:    nil,
		DatabaseURL:             strings.TrimSpace(os.Getenv("DATABASE_URL")),
		TermsVersion:            env("TERMS_VERSION", "terms-1"),
		PrivacyVersion:          env("PRIVACY_VERSION", "privacy-1"),
		EmailMode:               env("EMAIL_MODE", "console"),
		SMTPAddr:                strings.TrimSpace(os.Getenv("SMTP_ADDR")),
		SMTPTLSMode:             env("SMTP_TLS_MODE", "starttls"),
		SMTPUsername:            os.Getenv("SMTP_USERNAME"),
		SMTPPassword:            os.Getenv("SMTP_PASSWORD"),
		SMTPFrom:                strings.TrimSpace(os.Getenv("SMTP_FROM")),
		AppleEnabled:            strings.EqualFold(env("APPLE_ENABLED", "false"), "true"),
		AppleTeamID:             strings.TrimSpace(os.Getenv("APPLE_TEAM_ID")),
		AppleKeyID:              strings.TrimSpace(os.Getenv("APPLE_KEY_ID")),
		ApplePrivateKeyFile:     strings.TrimSpace(os.Getenv("APPLE_PRIVATE_KEY_FILE")),
		AppleClientIDs:          splitList(os.Getenv("APPLE_CLIENT_IDS")),
		SecurityJournalEndpoint: strings.TrimSpace(os.Getenv("SECURITY_JOURNAL_ENDPOINT")),
		SecurityJournalToken:    os.Getenv("SECURITY_JOURNAL_TOKEN"),
		SecurityJournalMode:     env("SECURITY_JOURNAL_MODE", "offsite"),
		DownloadDir:             strings.TrimSpace(os.Getenv("DOWNLOAD_DIR")),
		OfficialAIBaseURL:       strings.TrimSpace(os.Getenv("OFFICIAL_AI_BASE_URL")),
		OfficialAIAPIKey:        strings.TrimSpace(os.Getenv("OFFICIAL_AI_API_KEY")),
		OfficialAIModel:         env("OFFICIAL_AI_MODEL", "deepseek-chat"),
	}

	var err error
	if c.AuthHMACKey, err = secret32("AUTH_HMAC_KEY"); err != nil {
		return Config{}, err
	}
	if c.OutboxEncryptionKey, err = secret32("OUTBOX_ENCRYPTION_KEY"); err != nil {
		return Config{}, err
	}
	if c.IdempotencyKey, err = secret32("IDEMPOTENCY_ENCRYPTION_KEY"); err != nil {
		return Config{}, err
	}
	if c.AppleTokenEncryptionKey, err = secret32("APPLE_TOKEN_ENCRYPTION_KEY"); err != nil {
		return Config{}, err
	}
	if c.SecurityJournalKey, err = secret32Optional("SECURITY_JOURNAL_SIGNING_KEY"); err != nil {
		return Config{}, err
	}
	if c.AdminTOTPEncryptionKey, err = secret32Optional("ADMIN_TOTP_ENCRYPTION_KEY"); err != nil {
		return Config{}, err
	}
	if c.AdminAuditHMACKey, err = secret32Optional("ADMIN_AUDIT_HMAC_KEY"); err != nil {
		return Config{}, err
	}
	if c.AdminAllowedNetworks, err = parseAllowedNetworks(os.Getenv("ADMIN_ALLOWED_IPS")); err != nil {
		return Config{}, fmt.Errorf("ADMIN_ALLOWED_IPS is invalid: %w", err)
	}
	keys := [][]byte{c.AuthHMACKey, c.OutboxEncryptionKey, c.IdempotencyKey, c.AppleTokenEncryptionKey}
	if len(c.SecurityJournalKey) > 0 {
		keys = append(keys, c.SecurityJournalKey)
	}
	if len(c.AdminTOTPEncryptionKey) > 0 {
		keys = append(keys, c.AdminTOTPEncryptionKey)
	}
	if len(c.AdminAuditHMACKey) > 0 {
		keys = append(keys, c.AdminAuditHMACKey)
	}
	for i := range keys {
		for j := 0; j < i; j++ {
			if bytes.Equal(keys[i], keys[j]) {
				return Config{}, fmt.Errorf("cryptographic keys must be distinct; %d and %d reuse the same value", j+1, i+1)
			}
		}
	}

	if c.Environment != "development" && c.Environment != "test" && c.Environment != "production" {
		return Config{}, fmt.Errorf("APP_ENV must be development, test, or production")
	}
	if c.AccountAuthMode != "email_and_apple" && c.AccountAuthMode != "email_only" {
		return Config{}, fmt.Errorf("ACCOUNT_AUTH_MODE must be email_and_apple or email_only")
	}
	if c.AccountAuthMode == "email_only" && c.AppleEnabled {
		return Config{}, fmt.Errorf("email_only mode requires APPLE_ENABLED=false")
	}
	if c.DatabaseURL == "" {
		return Config{}, fmt.Errorf("DATABASE_URL is required")
	}
	if c.SecurityJournalMode != "offsite" && c.SecurityJournalMode != "login_only" {
		return Config{}, fmt.Errorf("SECURITY_JOURNAL_MODE must be offsite or login_only")
	}
	if c.DownloadDir != "" && !filepath.IsAbs(c.DownloadDir) {
		return Config{}, fmt.Errorf("DOWNLOAD_DIR must be an absolute path when set")
	}
	if c.OfficialAIBaseURL != "" {
		parsed, err := url.Parse(c.OfficialAIBaseURL)
		if err != nil || (parsed.Scheme != "https" && parsed.Scheme != "http") || parsed.Host == "" {
			return Config{}, fmt.Errorf("OFFICIAL_AI_BASE_URL must be an http(s) URL")
		}
	}
	limitText := strings.TrimSpace(os.Getenv("OFFICIAL_AI_MONTHLY_TOKEN_LIMIT"))
	if limitText == "" {
		c.OfficialAIMonthlyTokenLimit = 200_000
	} else {
		limit, err := strconv.ParseInt(limitText, 10, 64)
		if err != nil || limit <= 0 {
			return Config{}, fmt.Errorf("OFFICIAL_AI_MONTHLY_TOKEN_LIMIT must be a positive integer")
		}
		c.OfficialAIMonthlyTokenLimit = limit
	}
	journalConfigured := c.SecurityJournalEndpoint != "" || c.SecurityJournalToken != "" || len(c.SecurityJournalKey) > 0
	if c.SecurityJournalMode == "login_only" && journalConfigured {
		return Config{}, fmt.Errorf("login_only mode cannot include security journal credentials")
	}
	u, err := url.Parse(c.DatabaseURL)
	if err != nil || u.Scheme != "postgres" && u.Scheme != "postgresql" || u.Host == "" {
		return Config{}, fmt.Errorf("DATABASE_URL must be a PostgreSQL URL")
	}
	if c.EmailMode != "console" && c.EmailMode != "smtp" {
		return Config{}, fmt.Errorf("EMAIL_MODE must be console or smtp")
	}
	if c.SMTPTLSMode != "starttls" && c.SMTPTLSMode != "implicit" && c.SMTPTLSMode != "loopback" {
		return Config{}, fmt.Errorf("SMTP_TLS_MODE must be starttls, implicit, or loopback")
	}
	if !adminOnly && c.EmailMode == "smtp" {
		if c.SMTPAddr == "" || c.SMTPFrom == "" {
			return Config{}, fmt.Errorf("SMTP_ADDR and SMTP_FROM are required when EMAIL_MODE=smtp")
		}
		host, _, err := net.SplitHostPort(c.SMTPAddr)
		if err != nil {
			return Config{}, fmt.Errorf("SMTP_ADDR must include host and port")
		}
		if c.SMTPTLSMode == "loopback" {
			ip := net.ParseIP(host)
			if ip == nil || !ip.IsLoopback() || c.SMTPUsername != "" || c.SMTPPassword != "" {
				return Config{}, fmt.Errorf("loopback SMTP mode requires a loopback IP and no SMTP credentials")
			}
		}
	}
	if !adminOnly && c.AppleEnabled && (c.AppleTeamID == "" || c.AppleKeyID == "" || c.ApplePrivateKeyFile == "" || len(c.AppleClientIDs) == 0) {
		return Config{}, fmt.Errorf("Apple auth requires APPLE_TEAM_ID, APPLE_KEY_ID, APPLE_PRIVATE_KEY_FILE, and APPLE_CLIENT_IDS")
	}
	if c.Environment == "production" {
		databaseHost := net.ParseIP(u.Hostname())
		if u.Hostname() != "localhost" && (databaseHost == nil || !databaseHost.IsLoopback()) {
			return Config{}, fmt.Errorf("production PostgreSQL must be reachable only over a local address")
		}
		if !adminOnly && c.EmailMode != "smtp" {
			return Config{}, fmt.Errorf("production requires EMAIL_MODE=smtp")
		}
		if c.AdminEnabled {
			if len(c.AdminTOTPEncryptionKey) != 32 || len(c.AdminAuditHMACKey) != 32 {
				return Config{}, fmt.Errorf("production administrator console requires two distinct 32-byte keys")
			}
			if c.AdminOrigin != "https://admin.flowriver.xyz" {
				return Config{}, fmt.Errorf("production administrator console origin must be https://admin.flowriver.xyz")
			}
			if len(c.AdminAllowedNetworks) == 0 {
				return Config{}, fmt.Errorf("production administrator console requires at least one ADMIN_ALLOWED_IPS address or CIDR")
			}
			adminAddr, _, adminErr := net.SplitHostPort(c.AdminListenAddr)
			adminIP := net.ParseIP(adminAddr)
			if adminErr != nil || adminIP == nil || !adminIP.IsLoopback() {
				return Config{}, fmt.Errorf("production administrator API must listen on loopback behind the HTTPS proxy")
			}
		}
		if !adminOnly && c.AccountAuthMode == "email_and_apple" && !c.AppleEnabled {
			return Config{}, fmt.Errorf("production requires Apple auth when ACCOUNT_AUTH_MODE=email_and_apple")
		}
		if !adminOnly && c.SecurityJournalMode == "offsite" && (c.SecurityJournalEndpoint == "" || c.SecurityJournalToken == "" || len(c.SecurityJournalKey) != 32) {
			return Config{}, fmt.Errorf("production requires an off-host security journal endpoint, token, and 32-byte signing key")
		}
		if !adminOnly && c.SecurityJournalEndpoint != "" {
			journalURL, journalErr := url.Parse(c.SecurityJournalEndpoint)
			if journalErr != nil || journalURL.Scheme != "https" || journalURL.Host == "" {
				return Config{}, fmt.Errorf("production security journal endpoint must use HTTPS")
			}
		}
		if !adminOnly {
			addr, _, err := net.SplitHostPort(c.ListenAddr)
			if err != nil {
				return Config{}, fmt.Errorf("LISTEN_ADDR must include a port")
			}
			ip := net.ParseIP(addr)
			if ip == nil || !ip.IsLoopback() {
				return Config{}, fmt.Errorf("production API must listen on loopback behind the HTTPS proxy")
			}
		}
	}
	return c, nil
}

func parseAllowedNetworks(raw string) ([]net.IPNet, error) {
	var networks []net.IPNet
	for _, value := range strings.Split(raw, ",") {
		value = strings.TrimSpace(value)
		if value == "" {
			continue
		}
		if ip := net.ParseIP(value); ip != nil {
			prefix := 128
			if v4 := ip.To4(); v4 != nil {
				ip, prefix = v4, 32
			}
			mask := net.CIDRMask(prefix, prefix)
			networks = append(networks, net.IPNet{IP: ip, Mask: mask})
			continue
		}
		_, network, err := net.ParseCIDR(value)
		if err != nil {
			return nil, err
		}
		networks = append(networks, *network)
	}
	return networks, nil
}

func secret32(name string) ([]byte, error) {
	b, err := secret32Optional(name)
	if err != nil {
		return nil, err
	}
	if len(b) != 32 {
		return nil, fmt.Errorf("%s must be base64 for exactly 32 random bytes", name)
	}
	return b, nil
}

func secret32Optional(name string) ([]byte, error) {
	raw := strings.TrimSpace(os.Getenv(name))
	if raw == "" {
		return nil, nil
	}
	b, err := base64.RawStdEncoding.DecodeString(raw)
	if err != nil {
		b, err = base64.StdEncoding.DecodeString(raw)
	}
	if err != nil {
		return nil, fmt.Errorf("%s must be base64 encoded", name)
	}
	if len(b) != 32 {
		return nil, fmt.Errorf("%s must decode to exactly 32 bytes", name)
	}
	return b, nil
}

func env(name, fallback string) string {
	if value := strings.TrimSpace(os.Getenv(name)); value != "" {
		return value
	}
	return fallback
}

func splitList(value string) []string {
	var out []string
	for _, item := range strings.Split(value, ",") {
		if item = strings.TrimSpace(item); item != "" {
			out = append(out, item)
		}
	}
	return out
}
