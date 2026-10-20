package identity

import "testing"

func TestParseEmailCanonicalization(t *testing.T) {
	got, err := ParseEmail("Person@BÜCHER.example")
	if err != nil {
		t.Fatal(err)
	}
	if got.Canonical != "Person@xn--bcher-kva.example" {
		t.Fatalf("canonical = %q", got.Canonical)
	}
	if got.Display != "Person@BÜCHER.example" {
		t.Fatalf("display = %q", got.Display)
	}
}

func TestParseEmailPreservesLocalPartPolicy(t *testing.T) {
	upper, err := ParseEmail("Name@example.org")
	if err != nil {
		t.Fatal(err)
	}
	lower, err := ParseEmail("name@example.org")
	if err != nil {
		t.Fatal(err)
	}
	if upper.Canonical == lower.Canonical {
		t.Fatal("local-part case was folded unexpectedly")
	}
	plus, err := ParseEmail("name+tag@example.org")
	if err != nil {
		t.Fatal(err)
	}
	if plus.Canonical != "name+tag@example.org" {
		t.Fatalf("provider-specific alias changed: %q", plus.Canonical)
	}
}

func TestParseEmailRejectsDisplayNamesAndSMTPUTF8LocalPart(t *testing.T) {
	for _, input := range []string{"Person <person@example.org>", "姓名@example.org", "bad@@example.org", "person@localhost"} {
		if _, err := ParseEmail(input); err == nil {
			t.Errorf("ParseEmail(%q) unexpectedly succeeded", input)
		}
	}
}
