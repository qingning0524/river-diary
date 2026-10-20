package httpapi

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"math/big"
	"net/http"
	"net/url"
	"os"
	"strings"
	"sync"
	"time"

	"flowriver/server/internal/config"
	"flowriver/server/internal/secure"
	"github.com/golang-jwt/jwt/v5"
)

const appleIssuer = "https://appleid.apple.com"

type AppleProvider struct {
	teamID        string
	keyID         string
	clientIDs     map[string]struct{}
	privateKey    *ecdsa.PrivateKey
	appleTokenBox *secure.Box
	client        *http.Client
	keysURL       string
	tokenURL      string
	revokeURL     string
	mu            sync.Mutex
	keys          map[string]any
	keysUntil     time.Time
	lastFetched   time.Time
}

type appleClaims struct {
	jwt.RegisteredClaims
	Nonce         string       `json:"nonce"`
	Email         string       `json:"email"`
	EmailVerified flexibleBool `json:"email_verified"`
	PrivateEmail  flexibleBool `json:"is_private_email"`
}

type flexibleBool bool

func (b *flexibleBool) UnmarshalJSON(data []byte) error {
	var value bool
	if json.Unmarshal(data, &value) == nil {
		*b = flexibleBool(value)
		return nil
	}
	var text string
	if err := json.Unmarshal(data, &text); err != nil {
		return errors.New("invalid boolean claim")
	}
	*b = flexibleBool(strings.EqualFold(text, "true"))
	return nil
}

func NewAppleProvider(cfg config.Config, box *secure.Box) (*AppleProvider, error) {
	data, err := os.ReadFile(cfg.ApplePrivateKeyFile)
	if err != nil {
		return nil, fmt.Errorf("read Apple private key")
	}
	key, err := parseApplePrivateKey(data)
	if err != nil {
		return nil, fmt.Errorf("parse Apple private key")
	}
	ids := make(map[string]struct{}, len(cfg.AppleClientIDs))
	for _, id := range cfg.AppleClientIDs {
		ids[id] = struct{}{}
	}
	return &AppleProvider{
		teamID: cfg.AppleTeamID, keyID: cfg.AppleKeyID, clientIDs: ids, privateKey: key, appleTokenBox: box,
		client:    &http.Client{Timeout: 5 * time.Second, CheckRedirect: func(_ *http.Request, _ []*http.Request) error { return http.ErrUseLastResponse }},
		keysURL:   "https://appleid.apple.com/auth/keys",
		tokenURL:  "https://appleid.apple.com/auth/token",
		revokeURL: "https://appleid.apple.com/auth/revoke",
		keys:      make(map[string]any),
	}, nil
}

func parseApplePrivateKey(data []byte) (*ecdsa.PrivateKey, error) {
	block, _ := pem.Decode(data)
	if block == nil {
		return nil, errors.New("Apple key is not PEM")
	}
	if key, err := x509.ParsePKCS8PrivateKey(block.Bytes); err == nil {
		if ec, ok := key.(*ecdsa.PrivateKey); ok && ec.Curve == elliptic.P256() {
			return ec, nil
		}
	}
	return x509.ParseECPrivateKey(block.Bytes)
}

func (p *AppleProvider) clientSecret(clientID string) (string, error) {
	now := time.Now()
	token := jwt.NewWithClaims(jwt.SigningMethodES256, jwt.MapClaims{
		"iss": p.teamID, "iat": now.Unix(), "exp": now.Add(5 * time.Minute).Unix(),
		"aud": appleIssuer, "sub": clientID,
	})
	token.Header["kid"] = p.keyID
	return token.SignedString(p.privateKey)
}

type appleJWKSet struct {
	Keys []struct {
		Kty string `json:"kty"`
		Kid string `json:"kid"`
		Use string `json:"use"`
		Alg string `json:"alg"`
		Crv string `json:"crv"`
		X   string `json:"x"`
		Y   string `json:"y"`
		N   string `json:"n"`
		E   string `json:"e"`
	} `json:"keys"`
}

func (p *AppleProvider) publicKey(ctx context.Context, kid string) (any, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	now := time.Now()
	if now.Before(p.keysUntil) {
		if key := p.keys[kid]; key != nil {
			return key, nil
		}
	}
	if !p.lastFetched.IsZero() && now.Sub(p.lastFetched) < time.Minute {
		return nil, errors.New("Apple key service temporarily unavailable during rotation")
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, p.keysURL, nil)
	if err != nil {
		return nil, err
	}
	response, err := p.client.Do(request)
	if err != nil {
		return nil, errors.New("Apple key service unavailable")
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return nil, errors.New("Apple key service unavailable")
	}
	data, err := io.ReadAll(io.LimitReader(response.Body, 64<<10))
	if err != nil {
		return nil, errors.New("Apple key response invalid")
	}
	var set appleJWKSet
	if err := json.Unmarshal(data, &set); err != nil {
		return nil, errors.New("Apple key response invalid")
	}
	next := make(map[string]any)
	for _, jwk := range set.Keys {
		if jwk.Kid == "" || jwk.Use != "sig" || (jwk.Alg != "" && jwk.Alg != "RS256") {
			continue
		}
		var key any
		if jwk.Kty == "RSA" && jwk.N != "" && jwk.E != "" {
			n, nerr := base64.RawURLEncoding.DecodeString(jwk.N)
			e, eerr := base64.RawURLEncoding.DecodeString(jwk.E)
			if nerr == nil && eerr == nil && len(e) > 0 {
				exponent := new(big.Int).SetBytes(e)
				if exponent.IsInt64() {
					key = &rsa.PublicKey{N: new(big.Int).SetBytes(n), E: int(exponent.Int64())}
				}
			}
		}
		if key != nil {
			next[jwk.Kid] = key
		}
	}
	if len(next) == 0 {
		return nil, errors.New("Apple returned no supported signing keys")
	}
	p.keys = next
	p.keysUntil = time.Now().Add(5 * time.Minute)
	p.lastFetched = time.Now()
	key := p.keys[kid]
	if key == nil {
		return nil, errors.New("Apple signing key not found")
	}
	return key, nil
}

func (p *AppleProvider) verifyIdentity(ctx context.Context, raw string) (*appleClaims, error) {
	claims := &appleClaims{}
	parser := jwt.NewParser(jwt.WithValidMethods([]string{"RS256"}), jwt.WithIssuer(appleIssuer), jwt.WithExpirationRequired(), jwt.WithLeeway(60*time.Second))
	parsed, err := parser.ParseWithClaims(raw, claims, func(token *jwt.Token) (any, error) {
		kid, _ := token.Header["kid"].(string)
		if kid == "" {
			return nil, errors.New("Apple token has no key ID")
		}
		return p.publicKey(ctx, kid)
	})
	if err != nil || parsed == nil || !parsed.Valid {
		return nil, errors.New("Apple identity token invalid")
	}
	if len(claims.Audience) != 1 {
		return nil, errors.New("Apple audience invalid")
	}
	if _, allowed := p.clientIDs[claims.Audience[0]]; !allowed {
		return nil, errors.New("Apple audience not allowed")
	}
	if claims.Subject == "" || claims.Nonce == "" {
		return nil, errors.New("Apple token is missing identity claims")
	}
	return claims, nil
}

type appleTokenResponse struct {
	AccessToken  string `json:"access_token"`
	TokenType    string `json:"token_type"`
	ExpiresIn    int64  `json:"expires_in"`
	RefreshToken string `json:"refresh_token"`
	IDToken      string `json:"id_token"`
	Error        string `json:"error"`
}

func (p *AppleProvider) exchange(ctx context.Context, clientID, code string) (appleTokenResponse, error) {
	secret, err := p.clientSecret(clientID)
	if err != nil {
		return appleTokenResponse{}, err
	}
	form := url.Values{"client_id": {clientID}, "client_secret": {secret}, "code": {code}, "grant_type": {"authorization_code"}}
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, p.tokenURL, strings.NewReader(form.Encode()))
	if err != nil {
		return appleTokenResponse{}, err
	}
	request.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	response, err := p.client.Do(request)
	if err != nil {
		return appleTokenResponse{}, errors.New("Apple token service unavailable")
	}
	defer response.Body.Close()
	data, err := io.ReadAll(io.LimitReader(response.Body, 64<<10))
	if err != nil {
		return appleTokenResponse{}, errors.New("Apple token response invalid")
	}
	var result appleTokenResponse
	if json.Unmarshal(data, &result) != nil || response.StatusCode != http.StatusOK || result.Error != "" {
		return appleTokenResponse{}, errors.New("Apple authorization code rejected")
	}
	if result.RefreshToken == "" || result.IDToken == "" {
		return appleTokenResponse{}, errors.New("Apple token response incomplete")
	}
	return result, nil
}

func (p *AppleProvider) Revoke(ctx context.Context, clientID, refreshToken string) error {
	secret, err := p.clientSecret(clientID)
	if err != nil {
		return err
	}
	form := url.Values{"client_id": {clientID}, "client_secret": {secret}, "token": {refreshToken}, "token_type_hint": {"refresh_token"}}
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, p.revokeURL, strings.NewReader(form.Encode()))
	if err != nil {
		return err
	}
	request.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	response, err := p.client.Do(request)
	if err != nil {
		return errors.New("Apple revocation service unavailable")
	}
	defer response.Body.Close()
	_, _ = io.Copy(io.Discard, io.LimitReader(response.Body, 4096))
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return errors.New("Apple revocation was not confirmed")
	}
	return nil
}

func hashAppleNonce(raw string) string {
	digest := sha256.Sum256([]byte(raw))
	return fmt.Sprintf("%x", digest[:])
}

func transientAppleFailure(err error) bool {
	if err == nil {
		return false
	}
	message := strings.ToLower(err.Error())
	return strings.Contains(message, "unavailable") || strings.Contains(message, "response invalid") || strings.Contains(message, "temporarily unavailable")
}

func (p *AppleProvider) verifyNotification(ctx context.Context, raw string) (*appleNotificationClaims, error) {
	claims := &appleNotificationClaims{}
	parser := jwt.NewParser(jwt.WithValidMethods([]string{"RS256"}), jwt.WithIssuer(appleIssuer), jwt.WithExpirationRequired(), jwt.WithLeeway(60*time.Second))
	token, err := parser.ParseWithClaims(raw, claims, func(token *jwt.Token) (any, error) {
		kid, _ := token.Header["kid"].(string)
		if kid == "" {
			return nil, errors.New("missing kid")
		}
		return p.publicKey(ctx, kid)
	})
	if err != nil || token == nil || !token.Valid || claims.Subject == "" || claims.ID == "" || len(claims.Audience) != 1 {
		return nil, errors.New("Apple notification invalid")
	}
	if _, ok := p.clientIDs[claims.Audience[0]]; !ok {
		return nil, errors.New("Apple notification audience invalid")
	}
	return claims, nil
}

type appleNotificationClaims struct {
	jwt.RegisteredClaims
	Events struct {
		Type string `json:"type"`
		Sub  string `json:"sub"`
	} `json:"events"`
}

func requestAppleCode(ctx context.Context, p *AppleProvider, clientID, code string) (appleTokenResponse, *appleClaims, error) {
	tokens, err := p.exchange(ctx, clientID, code)
	if err != nil {
		return appleTokenResponse{}, nil, err
	}
	claims, err := p.verifyIdentity(ctx, tokens.IDToken)
	if err != nil {
		return appleTokenResponse{}, nil, err
	}
	if claims.Audience[0] != clientID {
		return appleTokenResponse{}, nil, errors.New("Apple token client mismatch")
	}
	return tokens, claims, nil
}

func appleFingerprint(raw string) []byte { digest := sha256.Sum256([]byte(raw)); return digest[:] }
