package adminapi

import (
	"context"
	"crypto/rand"
	"crypto/subtle"
	"encoding/base32"
	"encoding/base64"
	"errors"
	"fmt"
	"net/url"
	"regexp"
	"strings"
	"time"

	"flowriver/server/internal/config"
	"flowriver/server/internal/secure"
	"github.com/jackc/pgx/v5/pgxpool"
	"golang.org/x/crypto/argon2"
)

const (
	argonMemoryKiB         = 64 * 1024
	argonIterations        = 3
	argonLanes      uint8  = 1
	argonKeyBytes   uint32 = 32
)

var usernamePattern = regexp.MustCompile(`^[a-zA-Z0-9][a-zA-Z0-9._-]{2,63}$`)

func normalizeUsername(raw string) (string, bool) {
	username := strings.ToLower(strings.TrimSpace(raw))
	return username, usernamePattern.MatchString(username)
}

func createPasswordHash(password string) (string, error) {
	if len(password) < 12 || len(password) > 128 {
		return "", errors.New("administrator password must be 12 to 128 bytes")
	}
	salt := make([]byte, 16)
	if _, err := rand.Read(salt); err != nil {
		return "", err
	}
	hash := argon2.IDKey([]byte(password), salt, argonIterations, argonMemoryKiB, argonLanes, argonKeyBytes)
	return fmt.Sprintf("argon2id$v=19$m=%d,t=%d,p=%d$%s$%s", argonMemoryKiB, argonIterations, argonLanes,
		base64.RawStdEncoding.EncodeToString(salt), base64.RawStdEncoding.EncodeToString(hash)), nil
}

func verifyPassword(encoded, password string) bool {
	parts := strings.Split(encoded, "$")
	if len(parts) != 5 || parts[0] != "argon2id" || parts[1] != "v=19" {
		return false
	}
	var memory, iterations, lanes uint32
	if _, err := fmt.Sscanf(parts[2], "m=%d,t=%d,p=%d", &memory, &iterations, &lanes); err != nil ||
		memory < 16*1024 || memory > 128*1024 || iterations < 1 || iterations > 5 || lanes < 1 || lanes > 2 {
		return false
	}
	salt, errSalt := base64.RawStdEncoding.DecodeString(parts[3])
	expected, errHash := base64.RawStdEncoding.DecodeString(parts[4])
	if errSalt != nil || errHash != nil || len(salt) < 16 || len(salt) > 32 || len(expected) != int(argonKeyBytes) {
		return false
	}
	actual := argon2.IDKey([]byte(password), salt, iterations, memory, uint8(lanes), uint32(len(expected)))
	return subtle.ConstantTimeCompare(expected, actual) == 1
}

func randomTOTPSecret() ([]byte, string, error) {
	secret := make([]byte, 20)
	if _, err := rand.Read(secret); err != nil {
		return nil, "", err
	}
	encoded := base32.StdEncoding.WithPadding(base32.NoPadding).EncodeToString(secret)
	return secret, encoded, nil
}

func totpProvisioningURI(username, secret string) string {
	values := url.Values{}
	values.Set("secret", secret)
	values.Set("issuer", "FlowRiver OS")
	values.Set("algorithm", "SHA1")
	values.Set("digits", "6")
	values.Set("period", "30")
	u := url.URL{Scheme: "otpauth", Host: "totp", Path: "/FlowRiver OS:" + username, RawQuery: values.Encode()}
	return u.String()
}

func randomUUID() (string, error) {
	var bytes [16]byte
	if _, err := rand.Read(bytes[:]); err != nil {
		return "", err
	}
	bytes[6] = (bytes[6] & 0x0f) | 0x40
	bytes[8] = (bytes[8] & 0x3f) | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", bytes[0:4], bytes[4:6], bytes[6:8], bytes[8:10], bytes[10:16]), nil
}

// CreateFirstAdmin is available only through the SSH-provisioning CLI. The
// provisioning URI contains the only plaintext copy of the TOTP secret.
func CreateFirstAdmin(ctx context.Context, db *pgxpool.Pool, cfg config.Config, rawUsername, password string) (string, error) {
	username, ok := normalizeUsername(rawUsername)
	if !ok {
		return "", errors.New("administrator username must be 3-64 ASCII letters, digits, dots, underscores or hyphens")
	}
	passwordHash, err := createPasswordHash(password)
	if err != nil {
		return "", err
	}
	secret, encodedSecret, err := randomTOTPSecret()
	if err != nil {
		return "", err
	}
	adminID, err := randomUUID()
	if err != nil {
		return "", err
	}
	box, err := secure.NewBox(cfg.AdminTOTPEncryptionKey)
	if err != nil {
		return "", errors.New("administrator TOTP encryption key is unavailable")
	}
	sealed, err := box.Seal(secret, []byte("flowriver-admin-totp:"+adminID))
	if err != nil {
		return "", errors.New("administrator TOTP secret could not be protected")
	}
	tx, err := db.Begin(ctx)
	if err != nil {
		return "", err
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(7483214057)`); err != nil {
		return "", err
	}
	var exists bool
	if err := tx.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM admin_accounts)`).Scan(&exists); err != nil {
		return "", err
	}
	if exists {
		return "", errors.New("administrator already exists; bootstrap is one-time only")
	}
	if _, err := tx.Exec(ctx, `INSERT INTO admin_accounts(id,username,password_hash,totp_secret_ciphertext)
		VALUES($1,$2,$3,$4)`, adminID, username, passwordHash, sealed); err != nil {
		return "", fmt.Errorf("create administrator: %w", err)
	}
	if _, err := tx.Exec(ctx, `INSERT INTO admin_audit_events(admin_id,action,result,request_id,ip_mac)
		VALUES($1,'admin.bootstrap','success','ssh-bootstrap',$2)`, adminID,
		secure.MAC(cfg.AdminAuditHMACKey, "admin-bootstrap", time.Now().UTC().Format(time.RFC3339))); err != nil {
		return "", fmt.Errorf("record administrator bootstrap: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return "", err
	}
	return totpProvisioningURI(username, encodedSecret), nil
}

// ResetAdminTOTP is an emergency SSH recovery command. Stop the API first;
// reset revokes all web sessions before issuing a new one-time enrollment URI.
func ResetAdminTOTP(ctx context.Context, db *pgxpool.Pool, cfg config.Config, rawUsername string) (string, error) {
	username, ok := normalizeUsername(rawUsername)
	if !ok {
		return "", errors.New("invalid administrator username")
	}
	secret, encodedSecret, err := randomTOTPSecret()
	if err != nil {
		return "", err
	}
	box, err := secure.NewBox(cfg.AdminTOTPEncryptionKey)
	if err != nil {
		return "", errors.New("administrator TOTP encryption key is unavailable")
	}
	tx, err := db.Begin(ctx)
	if err != nil {
		return "", err
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(7483214057)`); err != nil {
		return "", err
	}
	var adminID string
	if err := tx.QueryRow(ctx, `SELECT id::text FROM admin_accounts WHERE username=$1 AND disabled_at IS NULL FOR UPDATE`, username).Scan(&adminID); err != nil {
		return "", errors.New("active administrator not found")
	}
	sealed, err := box.Seal(secret, []byte("flowriver-admin-totp:"+adminID))
	if err != nil {
		return "", errors.New("administrator TOTP secret could not be protected")
	}
	if _, err := tx.Exec(ctx, `UPDATE admin_accounts SET totp_secret_ciphertext=$2,totp_last_step=-1 WHERE id=$1`, adminID, sealed); err != nil {
		return "", err
	}
	if _, err := tx.Exec(ctx, `UPDATE admin_sessions SET revoked_at=now() WHERE admin_id=$1 AND revoked_at IS NULL`, adminID); err != nil {
		return "", err
	}
	if _, err := tx.Exec(ctx, `INSERT INTO admin_audit_events(admin_id,action,result,request_id,ip_mac)
		VALUES($1,'admin.totp.reset','success','ssh-totp-reset',$2)`, adminID,
		secure.MAC(cfg.AdminAuditHMACKey, "admin-totp-reset", time.Now().UTC().Format(time.RFC3339))); err != nil {
		return "", err
	}
	if err := tx.Commit(ctx); err != nil {
		return "", err
	}
	return totpProvisioningURI(username, encodedSecret), nil
}

func ResetAdminPassword(ctx context.Context, db *pgxpool.Pool, cfg config.Config, rawUsername, password string) error {
	username, ok := normalizeUsername(rawUsername)
	if !ok {
		return errors.New("invalid administrator username")
	}
	passwordHash, err := createPasswordHash(password)
	if err != nil {
		return err
	}
	tx, err := db.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(7483214057)`); err != nil {
		return err
	}
	var id string
	if err := tx.QueryRow(ctx, `SELECT id::text FROM admin_accounts WHERE username=$1 AND disabled_at IS NULL FOR UPDATE`, username).Scan(&id); err != nil {
		return errors.New("active administrator not found")
	}
	if _, err := tx.Exec(ctx, `UPDATE admin_accounts SET password_hash=$2 WHERE id=$1`, id, passwordHash); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `UPDATE admin_sessions SET revoked_at=now() WHERE admin_id=$1 AND revoked_at IS NULL`, id); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `INSERT INTO admin_audit_events(admin_id,action,result,request_id,ip_mac) VALUES($1,'admin.password.reset','success','ssh-password-reset',$2)`, id, secure.MAC(cfg.AdminAuditHMACKey, "admin-password-reset", time.Now().UTC().Format(time.RFC3339))); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

func dummyPasswordHash() string {
	const dummySalt = "Zmxvd3JpdmVyLWFkbWluLWZha2Utc2FsdA"
	salt, _ := base64.RawStdEncoding.DecodeString(dummySalt)
	hash := argon2.IDKey([]byte("not-a-real-flowriver-admin-password"), salt, argonIterations, argonMemoryKiB, argonLanes, argonKeyBytes)
	return fmt.Sprintf("argon2id$v=19$m=%d,t=%d,p=%d$%s$%s", argonMemoryKiB, argonIterations, argonLanes,
		dummySalt, base64.RawStdEncoding.EncodeToString(hash))
}
