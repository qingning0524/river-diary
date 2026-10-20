package adminapi

import (
	"crypto/hmac"
	"crypto/sha1"
	"crypto/subtle"
	"encoding/binary"
	"fmt"
	"strconv"
	"time"
)

func totpCode(secret []byte, step int64) string {
	var counter [8]byte
	binary.BigEndian.PutUint64(counter[:], uint64(step))
	mac := hmac.New(sha1.New, secret)
	_, _ = mac.Write(counter[:])
	digest := mac.Sum(nil)
	index := digest[len(digest)-1] & 0x0f
	value := (uint32(digest[index])&0x7f)<<24 |
		uint32(digest[index+1])<<16 |
		uint32(digest[index+2])<<8 |
		uint32(digest[index+3])
	return fmt.Sprintf("%06d", value%1_000_000)
}

// acceptTOTP rejects a code that has already been used for this account.
func acceptTOTP(secret []byte, code string, now time.Time, lastStep int64) (int64, bool) {
	if len(code) != 6 {
		return 0, false
	}
	if _, err := strconv.Atoi(code); err != nil {
		return 0, false
	}
	current := now.Unix() / 30
	for step := current - 1; step <= current+1; step++ {
		if step <= lastStep {
			continue
		}
		if subtle.ConstantTimeCompare([]byte(totpCode(secret, step)), []byte(code)) == 1 {
			return step, true
		}
	}
	return 0, false
}
