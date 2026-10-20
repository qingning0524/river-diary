package securityjournal

import (
	"context"
	"time"
)

type Event struct {
	EventID    string    `json:"event_id"`
	UserID     string    `json:"user_id"`
	IdentityID string    `json:"identity_id,omitempty"`
	Kind       string    `json:"kind"`
	OccurredAt time.Time `json:"occurred_at"`
}

type Sink interface {
	Append(context.Context, Event) error
}
