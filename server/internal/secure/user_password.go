package secure

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/base64"
	"errors"
	"fmt"
	"strings"
	"unicode/utf8"

	"golang.org/x/crypto/argon2"
	"golang.org/x/text/unicode/norm"
)

const userPasswordMemory = 64 * 1024
const userPasswordIterations = 3

// Preserve spaces and case. NFC provides the same encoding for equivalent Unicode text.
func NormalizeUserPassword(password string) string { return norm.NFC.String(password) }
func ValidNewUserPassword(password string) bool {
	if !utf8.ValidString(password) || len(password) > 512 {
		return false
	}
	password = NormalizeUserPassword(password)
	n := utf8.RuneCountInString(password)
	if n < 15 || n > 128 || strings.TrimSpace(password) == "" {
		return false
	}
	switch strings.ToLower(password) {
	case "123456789012345", "1234567890123456", "passwordpassword", "passwordpasswordpassword", "qwertyuiopasdfgh", "riverdiaryriverdiary", "flowriverflowriver":
		return false
	}
	return true
}
func HashUserPassword(password string) (string, error) {
	if !ValidNewUserPassword(password) {
		return "", errors.New("password policy not met")
	}
	salt := make([]byte, 16)
	if _, err := rand.Read(salt); err != nil {
		return "", err
	}
	hash := argon2.IDKey([]byte(NormalizeUserPassword(password)), salt, userPasswordIterations, userPasswordMemory, 1, 32)
	return fmt.Sprintf("argon2id$v=19$m=%d,t=%d,p=1$%s$%s", userPasswordMemory, userPasswordIterations, base64.RawStdEncoding.EncodeToString(salt), base64.RawStdEncoding.EncodeToString(hash)), nil
}
func VerifyUserPassword(encoded, password string) bool {
	if !utf8.ValidString(password) || len(password) > 512 || utf8.RuneCountInString(password) > 128 {
		return false
	}
	parts := strings.Split(encoded, "$")
	if len(parts) != 5 || parts[0] != "argon2id" || parts[1] != "v=19" {
		return false
	}
	// Only the bounded parameters written by this service are accepted.
	if parts[2] != "m=65536,t=3,p=1" {
		return false
	}
	salt, err := base64.RawStdEncoding.DecodeString(parts[3])
	if err != nil || len(salt) != 16 {
		return false
	}
	expected, err := base64.RawStdEncoding.DecodeString(parts[4])
	if err != nil || len(expected) != 32 {
		return false
	}
	actual := argon2.IDKey([]byte(NormalizeUserPassword(password)), salt, userPasswordIterations, userPasswordMemory, 1, 32)
	return subtle.ConstantTimeCompare(expected, actual) == 1
}

// Invalid accounts still perform the same KDF. This is not a usable account credential.
func DummyUserPasswordHash() string {
	return "argon2id$v=19$m=65536,t=3,p=1$" + base64.RawStdEncoding.EncodeToString(make([]byte, 16)) + "$" + base64.RawStdEncoding.EncodeToString(make([]byte, 32))
}
