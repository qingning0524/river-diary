package secure

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"io"
)

type Box struct{ aead cipher.AEAD }

func NewBox(key []byte) (*Box, error) {
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}
	return &Box{aead: aead}, nil
}

func (b *Box) Seal(plaintext, associatedData []byte) ([]byte, error) {
	nonce := make([]byte, b.aead.NonceSize())
	if _, err := io.ReadFull(rand.Reader, nonce); err != nil {
		return nil, err
	}
	return b.aead.Seal(nonce, nonce, plaintext, associatedData), nil
}

func (b *Box) Open(ciphertext, associatedData []byte) ([]byte, error) {
	if len(ciphertext) < b.aead.NonceSize()+b.aead.Overhead() {
		return nil, errors.New("ciphertext too short")
	}
	nonce := ciphertext[:b.aead.NonceSize()]
	return b.aead.Open(nil, nonce, ciphertext[b.aead.NonceSize():], associatedData)
}

func MAC(key []byte, fields ...string) []byte {
	h := hmac.New(sha256.New, key)
	for _, field := range fields {
		_, _ = h.Write([]byte{byte(len(field) >> 24), byte(len(field) >> 16), byte(len(field) >> 8), byte(len(field))})
		_, _ = h.Write([]byte(field))
	}
	return h.Sum(nil)
}

func Digest(secret string) []byte {
	sum := sha256.Sum256([]byte(secret))
	return sum[:]
}

func EqualMAC(left, right []byte) bool { return hmac.Equal(left, right) }

func RandomToken(size int) (string, error) {
	buf := make([]byte, size)
	if _, err := io.ReadFull(rand.Reader, buf); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(buf), nil
}
