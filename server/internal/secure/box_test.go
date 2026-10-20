package secure

import (
	"bytes"
	"testing"
)

func TestBoxSealsAndAuthenticatesAssociatedData(t *testing.T) {
	key := bytes.Repeat([]byte{0x42}, 32)
	box, err := NewBox(key)
	if err != nil {
		t.Fatal(err)
	}
	plain := []byte("sensitive queued code")
	sealed, err := box.Seal(plain, []byte("job-1"))
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(sealed, []byte("sensitive queued code")) {
		t.Fatal("plaintext appears in ciphertext")
	}
	opened, err := box.Open(sealed, []byte("job-1"))
	if err != nil || !bytes.Equal(opened, plain) {
		t.Fatalf("Open() = %q, %v", opened, err)
	}
	if _, err := box.Open(sealed, []byte("job-2")); err == nil {
		t.Fatal("ciphertext opened with the wrong associated data")
	}
	sealed[len(sealed)-1] ^= 1
	if _, err := box.Open(sealed, []byte("job-1")); err == nil {
		t.Fatal("tampered ciphertext opened")
	}
}

func TestMACUsesFieldBoundaries(t *testing.T) {
	key := []byte("test-key")
	if bytes.Equal(MAC(key, "ab", "c"), MAC(key, "a", "bc")) {
		t.Fatal("field boundaries collided")
	}
}
