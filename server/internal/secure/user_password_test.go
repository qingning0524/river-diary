package secure

import (
	"strings"
	"testing"
)

func TestUserPasswordHashSaltAndVerification(t *testing.T) {
	password := "a quiet river phrase 2026"
	a, err := HashUserPassword(password)
	if err != nil {
		t.Fatal(err)
	}
	b, err := HashUserPassword(password)
	if err != nil {
		t.Fatal(err)
	}
	if a == b || strings.Contains(a, password) {
		t.Fatal("password salt or plaintext storage failure")
	}
	if !VerifyUserPassword(a, password) || VerifyUserPassword(a, password+"x") {
		t.Fatal("password verification failure")
	}
	if !VerifyUserPassword(a, NormalizeUserPassword(password)) {
		t.Fatal("normalization inconsistent")
	}
	for _, hash := range []string{"", "argon2id$v=19$m=999999999,t=3,p=1$AAAA$BBBB", strings.Replace(a, "m=65536", "m=131072", 1)} {
		if VerifyUserPassword(hash, password) {
			t.Fatal("unbounded or malformed hash accepted")
		}
	}
	if VerifyUserPassword(DummyUserPasswordHash(), password) {
		t.Fatal("dummy credential accepted")
	}
}
func TestUserPasswordPolicyAcceptsPassphrasesAndUnicode(t *testing.T) {
	for _, p := range []string{"", "short", strings.Repeat(" ", 20), strings.Repeat("x", 129), "123456789012345", "passwordpassword"} {
		if ValidNewUserPassword(p) {
			t.Fatal("weak or out-of-bounds password accepted")
		}
	}
	p := "  河流日记里的每一个平常日子都值得保存  "
	h, err := HashUserPassword(p)
	if err != nil {
		t.Fatal(err)
	}
	if !VerifyUserPassword(h, p) || VerifyUserPassword(h, strings.TrimSpace(p)) {
		t.Fatal("password spaces must be preserved")
	}
	composed := strings.Repeat("é", 15)
	decomposed := strings.Repeat("e\u0301", 15)
	h, err = HashUserPassword(composed)
	if err != nil || !VerifyUserPassword(h, decomposed) {
		t.Fatal("canonical Unicode forms did not match")
	}
}
