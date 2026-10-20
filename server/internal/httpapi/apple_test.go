package httpapi

import (
	"crypto/rand"
	"crypto/rsa"
	"encoding/base64"
	"encoding/json"
	"math/big"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"flowriver/server/internal/secure"
	"github.com/golang-jwt/jwt/v5"
)

func TestAppleIdentityTokenSignatureAndClaims(t *testing.T) {
	private, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	exponent := big.NewInt(int64(private.PublicKey.E)).Bytes()
	public := map[string]any{"keys": []map[string]string{{
		"kty": "RSA", "kid": "apple-test-key", "use": "sig", "alg": "RS256",
		"n": base64.RawURLEncoding.EncodeToString(private.PublicKey.N.Bytes()),
		"e": base64.RawURLEncoding.EncodeToString(exponent),
	}}}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/auth/keys" {
			http.NotFound(w, r)
			return
		}
		_ = json.NewEncoder(w).Encode(public)
	}))
	defer server.Close()
	provider := &AppleProvider{
		clientIDs: map[string]struct{}{"studio.riverdiary.ios": {}},
		client:    server.Client(), keysURL: server.URL + "/auth/keys", keys: make(map[string]any),
	}
	makeToken := func(audience, nonce string) string {
		claims := jwt.RegisteredClaims{Issuer: appleIssuer, Subject: "apple-user-123", Audience: []string{audience},
			ExpiresAt: jwt.NewNumericDate(time.Now().Add(2 * time.Minute)), IssuedAt: jwt.NewNumericDate(time.Now())}
		custom := appleClaims{RegisteredClaims: claims, Nonce: nonce, Email: "relay@example.org", EmailVerified: true}
		token := jwt.NewWithClaims(jwt.SigningMethodRS256, custom)
		token.Header["kid"] = "apple-test-key"
		encoded, err := token.SignedString(private)
		if err != nil {
			t.Fatal(err)
		}
		return encoded
	}

	valid := makeToken("studio.riverdiary.ios", hashAppleNonce("nonce-from-server"))
	claims, err := provider.verifyIdentity(t.Context(), valid)
	if err != nil {
		t.Fatalf("valid Apple token rejected: %v", err)
	}
	if claims.Subject != "apple-user-123" || claims.Nonce != hashAppleNonce("nonce-from-server") {
		t.Fatal("validated claims differ")
	}
	storedNonce := secure.MAC([]byte("unit-test-key"), "apple-nonce-v1", "attempt-1", hashAppleNonce("nonce-from-server"))
	if !secure.EqualMAC(storedNonce, secure.MAC([]byte("unit-test-key"), "apple-nonce-v1", "attempt-1", claims.Nonce)) {
		t.Fatal("correct nonce failed the server challenge")
	}
	if secure.EqualMAC(storedNonce, secure.MAC([]byte("unit-test-key"), "apple-nonce-v1", "attempt-1", hashAppleNonce("other-attempt"))) {
		t.Fatal("wrong nonce passed the server challenge")
	}

	if _, err := provider.verifyIdentity(t.Context(), makeToken("another.bundle.id", hashAppleNonce("nonce-from-server"))); err == nil {
		t.Fatal("token for another App ID was accepted")
	}
	if _, err := provider.verifyIdentity(t.Context(), makeToken("studio.riverdiary.ios", hashAppleNonce("another-attempt"))); err != nil {
		t.Fatalf("signature/claims should validate before the challenge-specific nonce comparison: %v", err)
	}
	badSignature, err := jwt.NewWithClaims(jwt.SigningMethodRS256, jwt.MapClaims{"iss": appleIssuer, "sub": "apple-user-123", "aud": "studio.riverdiary.ios", "exp": time.Now().Add(time.Minute).Unix(), "nonce": hashAppleNonce("nonce-from-server")}).SignedString(mustRSAKey(t))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := provider.verifyIdentity(t.Context(), badSignature); err == nil {
		t.Fatal("token signed with an unrelated key was accepted")
	}
}

func mustRSAKey(t *testing.T) *rsa.PrivateKey {
	t.Helper()
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	return key
}
