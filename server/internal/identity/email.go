package identity

import (
	"errors"
	"fmt"
	"net/mail"
	"strings"
	"unicode/utf8"

	"golang.org/x/net/idna"
)

type Email struct {
	Display   string
	Canonical string
}

func ParseEmail(input string) (Email, error) {
	display := strings.TrimSpace(input)
	if display == "" || len(display) > 320 || !utf8.ValidString(display) {
		return Email{}, errors.New("invalid email address")
	}
	parsed, err := mail.ParseAddress(display)
	if err != nil || parsed.Address != display {
		return Email{}, errors.New("enter one email address without a display name")
	}
	parts := strings.Split(parsed.Address, "@")
	if len(parts) != 2 || parts[0] == "" || parts[1] == "" || !utf8.ValidString(parts[0]) {
		return Email{}, errors.New("invalid email address")
	}
	for _, r := range parts[0] {
		if r > 127 {
			return Email{}, errors.New("internationalized email local parts are not supported yet")
		}
	}
	domain, err := idna.Lookup.ToASCII(parts[1])
	if err != nil || domain == "" || strings.Contains(domain, "..") {
		return Email{}, errors.New("invalid email domain")
	}
	domain = strings.ToLower(strings.TrimSuffix(domain, "."))
	if len(domain) > 253 || !strings.Contains(domain, ".") {
		return Email{}, errors.New("invalid email domain")
	}
	canonical := parts[0] + "@" + domain
	if len(canonical) > 254 {
		return Email{}, fmt.Errorf("email address is too long")
	}
	return Email{Display: display, Canonical: canonical}, nil
}
