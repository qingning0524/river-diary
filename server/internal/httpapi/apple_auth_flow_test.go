package httpapi

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/rsa"
	"encoding/base64"
	"encoding/json"
	"io"
	"log/slog"
	"math/big"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"flowriver/server/internal/jobs"
	"github.com/golang-jwt/jwt/v5"
)

func TestNativeAppleLoginSharesAccountAcrossGroupedAppIDs(t *testing.T) {
	api, db, sender := testAPI(t)
	appleSigningKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	clientPrivateKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	clientIDs := []string{"studio.riverdiary.ios", "studio.riverdiary.mac"}
	clientIDSet := map[string]struct{}{}
	for _, id := range clientIDs {
		clientIDSet[id] = struct{}{}
	}
	var currentNonce, currentClientID string
	const teamID = "TEAM123456"
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/auth/keys":
			exponent := big.NewInt(int64(appleSigningKey.PublicKey.E)).Bytes()
			_ = json.NewEncoder(w).Encode(map[string]any{"keys": []map[string]string{{"kty": "RSA", "kid": "apple-fixture", "use": "sig", "alg": "RS256", "n": base64.RawURLEncoding.EncodeToString(appleSigningKey.PublicKey.N.Bytes()), "e": base64.RawURLEncoding.EncodeToString(exponent)}}})
		case "/auth/token":
			if err := r.ParseForm(); err != nil {
				http.Error(w, "bad form", 400)
				return
			}
			clientID := r.Form.Get("client_id")
			if clientID != currentClientID || r.Form.Get("code") == "" || r.Form.Get("grant_type") != "authorization_code" {
				http.Error(w, "bad authorization exchange", 400)
				return
			}
			secretClaims := jwt.MapClaims{}
			parsed, err := jwt.ParseWithClaims(r.Form.Get("client_secret"), secretClaims, func(token *jwt.Token) (any, error) { return &clientPrivateKey.PublicKey, nil }, jwt.WithValidMethods([]string{"ES256"}), jwt.WithIssuer(teamID), jwt.WithAudience(appleIssuer), jwt.WithExpirationRequired())
			if err != nil || parsed == nil || !parsed.Valid || secretClaims["sub"] != clientID {
				http.Error(w, "bad client secret", 401)
				return
			}
			claims := jwt.MapClaims{"iss": appleIssuer, "aud": clientID, "sub": "stable-apple-subject", "nonce": currentNonce, "exp": time.Now().Add(2 * time.Minute).Unix(), "iat": time.Now().Unix(), "email": "relay@example.org", "email_verified": "true", "is_private_email": "true"}
			idToken := jwt.NewWithClaims(jwt.SigningMethodRS256, claims)
			idToken.Header["kid"] = "apple-fixture"
			encoded, err := idToken.SignedString(appleSigningKey)
			if err != nil {
				http.Error(w, "sign failed", 500)
				return
			}
			_ = json.NewEncoder(w).Encode(map[string]any{"access_token": "fixture-access", "token_type": "Bearer", "expires_in": 300, "refresh_token": "fixture-refresh-" + clientID, "id_token": encoded})
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()
	api.apple = &AppleProvider{teamID: teamID, keyID: "FIXTURE1", clientIDs: clientIDSet, privateKey: clientPrivateKey, client: server.Client(), keysURL: server.URL + "/auth/keys", tokenURL: server.URL + "/auth/token", revokeURL: server.URL + "/auth/revoke", keys: map[string]any{}}
	httpServer := httptest.NewServer(api.Handler())
	defer httpServer.Close()
	client := httpServer.Client()
	login := func(clientID, instance, code string) TokenResponse {
		t.Helper()
		currentClientID = clientID
		status, start := doJSON(t, client, http.MethodPost, httpServer.URL+"/v1/auth/apple/start", "", "", map[string]any{})
		if status != http.StatusOK {
			t.Fatalf("Apple start=%d %s", status, start)
		}
		var attempt struct {
			ID    string `json:"attempt_id"`
			Nonce string `json:"nonce"`
		}
		if err := json.Unmarshal(start, &attempt); err != nil {
			t.Fatal(err)
		}
		currentNonce = hashAppleNonce(attempt.Nonce)
		claims := jwt.MapClaims{"iss": appleIssuer, "aud": clientID, "sub": "stable-apple-subject", "nonce": currentNonce, "exp": time.Now().Add(2 * time.Minute).Unix(), "iat": time.Now().Unix(), "email": "relay@example.org", "email_verified": true}
		idToken := jwt.NewWithClaims(jwt.SigningMethodRS256, claims)
		idToken.Header["kid"] = "apple-fixture"
		token, err := idToken.SignedString(appleSigningKey)
		if err != nil {
			t.Fatal(err)
		}
		status, response := doJSON(t, client, http.MethodPost, httpServer.URL+"/v1/auth/apple/complete", code, "", map[string]any{"attempt_id": attempt.ID, "identity_token": token, "authorization_code": code, "client_instance_id": instance, "platform": "other", "accept_terms": true})
		if status != http.StatusOK {
			t.Fatalf("Apple complete=%d %s", status, response)
		}
		var result TokenResponse
		if err := json.Unmarshal(response, &result); err != nil {
			t.Fatal(err)
		}
		return result
	}
	first := login(clientIDs[0], "650e8400-e29b-41d4-a716-446655440010", "auth-code-ios")
	second := login(clientIDs[1], "650e8400-e29b-41d4-a716-446655440011", "auth-code-mac")
	if first.User.ID != second.User.ID || !first.Created || second.Created {
		t.Fatalf("grouped Apple apps did not resolve to one user: first=%s second=%s", first.User.ID, second.User.ID)
	}
	var users, identities, devices int
	if err := db.QueryRow(context.Background(), `SELECT count(*) FROM users`).Scan(&users); err != nil {
		t.Fatal(err)
	}
	if err := db.QueryRow(context.Background(), `SELECT count(*) FROM identities WHERE provider='apple'`).Scan(&identities); err != nil {
		t.Fatal(err)
	}
	if err := db.QueryRow(context.Background(), `SELECT count(*) FROM devices`).Scan(&devices); err != nil {
		t.Fatal(err)
	}
	if users != 1 || identities != 1 || devices != 2 {
		t.Fatalf("Apple identity rows: users=%d identities=%d devices=%d", users, identities, devices)
	}
	var tokenCiphertext []byte
	if err := db.QueryRow(context.Background(), `SELECT refresh_token_ciphertext FROM identities WHERE provider='apple'`).Scan(&tokenCiphertext); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(tokenCiphertext), "fixture-refresh-") {
		t.Fatal("Apple refresh token was stored in plaintext")
	}
	// Apple's private relay email is contact data, not the product account key.
	status, _ := doJSON(t, client, http.MethodPost, httpServer.URL+"/v1/auth/email/start", "", "", map[string]string{"email": "relay@example.org"})
	if status != http.StatusAccepted {
		t.Fatalf("email login for Apple contact address=%d", status)
	}
	var emailChallenge string
	if err := db.QueryRow(context.Background(), `SELECT id::text FROM auth_challenges WHERE purpose='email_login'`).Scan(&emailChallenge); err != nil {
		t.Fatal(err)
	}
	worker := &jobs.EmailWorker{DB: db, Box: api.outboxBox, Sender: sender, Log: slog.New(slog.NewTextHandler(io.Discard, nil))}
	if worked, err := worker.DeliverOne(context.Background()); err != nil || !worked {
		t.Fatalf("email delivery: worked=%v err=%v", worked, err)
	}
	_, emailCode := sender.value()
	status, emailResponse := doJSON(t, client, http.MethodPost, httpServer.URL+"/v1/auth/email/verify", "email-relay1", "", map[string]any{"challenge_id": emailChallenge, "code": emailCode, "client_instance_id": "650e8400-e29b-41d4-a716-446655440012", "platform": "ios", "accept_terms": true})
	if status != http.StatusOK {
		t.Fatalf("email login with Apple contact address=%d %s", status, emailResponse)
	}
	var emailAccount TokenResponse
	if err := json.Unmarshal(emailResponse, &emailAccount); err != nil {
		t.Fatal(err)
	}
	if emailAccount.User.ID == first.User.ID || !emailAccount.Created {
		t.Fatal("matching Apple/email addresses were silently merged")
	}
	if err := db.QueryRow(context.Background(), `SELECT count(*) FROM users`).Scan(&users); err != nil {
		t.Fatal(err)
	}
	if users != 2 {
		t.Fatalf("Apple/email identity auto-merge created %d users, want 2 until the user links them", users)
	}
}
