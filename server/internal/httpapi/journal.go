package httpapi

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"

	"flowriver/server/internal/config"
	"flowriver/server/internal/securityjournal"
)

type SecurityEvent = securityjournal.Event
type SecurityJournal = securityjournal.Sink

type HTTPSecurityJournal struct {
	endpoint string
	token    string
	key      []byte
	client   *http.Client
}

func NewHTTPSecurityJournal(cfg config.Config) (*HTTPSecurityJournal, error) {
	u, err := url.Parse(cfg.SecurityJournalEndpoint)
	if err != nil || u.Scheme != "https" || u.Host == "" {
		return nil, fmt.Errorf("security journal endpoint must use HTTPS")
	}
	return &HTTPSecurityJournal{
		endpoint: strings.TrimRight(u.String(), "/"), token: cfg.SecurityJournalToken, key: cfg.SecurityJournalKey,
		client: &http.Client{Timeout: 5 * time.Second, CheckRedirect: func(_ *http.Request, _ []*http.Request) error { return http.ErrUseLastResponse }},
	}, nil
}

func (j *HTTPSecurityJournal) Append(ctx context.Context, event SecurityEvent) error {
	body, err := json.Marshal(event)
	if err != nil {
		return err
	}
	timestamp := fmt.Sprintf("%d", time.Now().UTC().Unix())
	mac := hmac.New(sha256.New, j.key)
	_, _ = mac.Write([]byte(timestamp + "\n"))
	_, _ = mac.Write(body)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, j.endpoint+"/v1/events", bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+j.token)
	req.Header.Set("X-FlowRiver-Timestamp", timestamp)
	req.Header.Set("X-FlowRiver-Signature", "v1="+hex.EncodeToString(mac.Sum(nil)))
	response, err := j.client.Do(req)
	if err != nil {
		return fmt.Errorf("security journal request failed")
	}
	defer response.Body.Close()
	responseBody, err := io.ReadAll(io.LimitReader(response.Body, 4097))
	if err != nil || len(responseBody) > 4096 {
		return fmt.Errorf("security journal response invalid")
	}
	if response.StatusCode != http.StatusOK && response.StatusCode != http.StatusCreated && response.StatusCode != http.StatusConflict {
		return fmt.Errorf("security journal did not confirm event")
	}
	var receipt struct {
		EventID string `json:"event_id"`
		Stored  bool   `json:"stored"`
	}
	if json.Unmarshal(responseBody, &receipt) != nil || receipt.EventID != event.EventID || !receipt.Stored {
		return fmt.Errorf("security journal receipt did not match event")
	}
	return nil
}
