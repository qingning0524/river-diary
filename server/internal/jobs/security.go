package jobs

import (
	"context"
	"crypto/rand"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"math"
	"time"

	"flowriver/server/internal/secure"
	"flowriver/server/internal/securityjournal"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type SecurityWorker struct {
	DB      *pgxpool.Pool
	Journal securityjournal.Sink
	Box     *secure.Box
	Log     *slog.Logger
}

func (w *SecurityWorker) Run(ctx context.Context) {
	ticker := time.NewTicker(1500 * time.Millisecond)
	defer ticker.Stop()
	for {
		worked, err := w.DeliverOne(ctx)
		if err != nil && ctx.Err() == nil {
			w.Log.Error("security event worker failed", "error_code", "security_worker_database_error")
		}
		if worked {
			continue
		}
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}

func (w *SecurityWorker) DeliverOne(ctx context.Context) (bool, error) {
	tx, err := w.DB.Begin(ctx)
	if err != nil {
		return false, err
	}
	defer tx.Rollback(ctx)
	var event securityjournal.Event
	err = tx.QueryRow(ctx, `SELECT event_id::text,old_user_id::text,COALESCE(identity_id::text,''),event_type,occurred_at
		FROM security_event_outbox WHERE delivered_at IS NULL AND available_at<=now()
		AND (lease_until IS NULL OR lease_until<=now()) ORDER BY occurred_at
		FOR UPDATE SKIP LOCKED LIMIT 1`).Scan(&event.EventID, &event.UserID, &event.IdentityID, &event.Kind, &event.OccurredAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	if _, err := tx.Exec(ctx, `UPDATE security_event_outbox SET lease_until=now()+interval '15 seconds' WHERE event_id=$1`, event.EventID); err != nil {
		return false, err
	}
	if err := tx.Commit(ctx); err != nil {
		return false, err
	}
	if w.Journal == nil {
		return true, w.retry(ctx, event.EventID)
	}
	if err := w.Journal.Append(ctx, event); err != nil {
		return true, w.retry(ctx, event.EventID)
	}
	return true, w.apply(ctx, event)
}

func (w *SecurityWorker) retry(ctx context.Context, eventID string) error {
	var attempts int
	err := w.DB.QueryRow(ctx, `UPDATE security_event_outbox SET attempts=attempts+1,
		available_at=now()+$2::interval,lease_until=NULL,last_error_code='journal_unavailable'
		WHERE event_id=$1 RETURNING attempts`, eventID, (30 * time.Second).String()).Scan(&attempts)
	if err != nil {
		return err
	}
	if attempts > 12 {
		_, err = w.DB.Exec(ctx, `UPDATE security_event_outbox SET available_at=now()+interval '1 hour' WHERE event_id=$1`, eventID)
	}
	return err
}

func (w *SecurityWorker) apply(ctx context.Context, event securityjournal.Event) error {
	tx, err := w.DB.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	var delivered bool
	if err := tx.QueryRow(ctx, `SELECT delivered_at IS NOT NULL FROM security_event_outbox WHERE event_id=$1 FOR UPDATE`, event.EventID).Scan(&delivered); err != nil {
		return err
	}
	if delivered {
		return tx.Commit(ctx)
	}
	if event.Kind == "account_deleted" {
		if _, err := tx.Exec(ctx, `UPDATE audit_events SET user_id=NULL WHERE user_id=$1`, event.UserID); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `DELETE FROM users WHERE id=$1 AND status='deleting'`, event.UserID); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `UPDATE deletion_jobs SET completed_at=COALESCE(completed_at,now()) WHERE old_user_id=$1`, event.UserID); err != nil {
			return err
		}
	} else if event.Kind == "identity_revoked" && event.IdentityID != "" {
		var provider, clientID string
		var tokenCiphertext []byte
		identityErr := tx.QueryRow(ctx, `SELECT provider,COALESCE(provider_client_id,''),refresh_token_ciphertext
			FROM identities WHERE id=$1 AND user_id=$2 FOR UPDATE`, event.IdentityID, event.UserID).Scan(&provider, &clientID, &tokenCiphertext)
		if identityErr != nil && !errors.Is(identityErr, pgx.ErrNoRows) {
			return identityErr
		}
		manual := false
		if identityErr == nil && provider == "apple" && len(tokenCiphertext) > 0 && w.Box != nil {
			refresh, err := w.Box.Open(tokenCiphertext, []byte("flowriver-apple-refresh-v1|"+event.IdentityID))
			if err != nil {
				manual = true
			} else {
				jobID, err := newUUID()
				if err != nil {
					return err
				}
				payload, err := json.Marshal(map[string]string{"client_id": clientID, "refresh_token": string(refresh)})
				if err != nil {
					return err
				}
				sealed, err := w.Box.Seal(payload, []byte("flowriver-outbox-v1|"+jobID+"|apple_revoke"))
				if err != nil {
					return err
				}
				if _, err := tx.Exec(ctx, `INSERT INTO outbox_jobs(id,kind,payload_ciphertext,created_at,available_at,expires_at)
					VALUES($1,'apple_revoke',$2,now(),now(),now()+interval '24 hours')`, jobID, sealed); err != nil {
					return err
				}
			}
		} else if identityErr == nil && provider == "apple" {
			manual = true
		}
		if identityErr == nil {
			if _, err := tx.Exec(ctx, `UPDATE identities SET status='revoked',refresh_token_ciphertext=NULL,updated_at=now() WHERE id=$1 AND user_id=$2`, event.IdentityID, event.UserID); err != nil {
				return err
			}
			if _, err := tx.Exec(ctx, `UPDATE sessions SET status='revoked',revoked_at=COALESCE(revoked_at,now()) WHERE identity_id=$1`, event.IdentityID); err != nil {
				return err
			}
			if _, err := tx.Exec(ctx, `UPDATE users SET status='recovery_required' WHERE id=$1 AND NOT EXISTS(SELECT 1 FROM identities WHERE user_id=$1 AND status='active')`, event.UserID); err != nil {
				return err
			}
		}
		if manual {
			if _, err := tx.Exec(ctx, `UPDATE security_event_outbox SET last_error_code='apple_revocation_manual_action' WHERE event_id=$1`, event.EventID); err != nil {
				return err
			}
		}
	}
	if _, err := tx.Exec(ctx, `UPDATE security_event_outbox SET delivered_at=now(),lease_until=NULL,
		last_error_code=CASE WHEN last_error_code='apple_revocation_manual_action' THEN last_error_code ELSE NULL END WHERE event_id=$1`, event.EventID); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

func newUUID() (string, error) {
	var id [16]byte
	if _, err := rand.Read(id[:]); err != nil {
		return "", err
	}
	id[6] = (id[6] & 0x0f) | 0x40
	id[8] = (id[8] & 0x3f) | 0x80
	return fmt.Sprintf("%08x-%04x-%04x-%04x-%012x", id[0:4], id[4:6], id[6:8], id[8:10], id[10:16]), nil
}

type AppleRevokeWorker struct {
	DB    *pgxpool.Pool
	Box   *secure.Box
	Apple interface {
		Revoke(context.Context, string, string) error
	}
	Log *slog.Logger
}

type revokePayload struct {
	ClientID      string `json:"client_id"`
	RefreshToken  string `json:"refresh_token"`
	DeletionJobID string `json:"deletion_job_id"`
}

func (w *AppleRevokeWorker) Run(ctx context.Context) {
	ticker := time.NewTicker(2 * time.Second)
	defer ticker.Stop()
	for {
		worked, err := w.DeliverOne(ctx)
		if err != nil && ctx.Err() == nil {
			w.Log.Error("Apple revocation worker failed", "error_code", "apple_revoke_worker_error")
		}
		if worked {
			continue
		}
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}

func (w *AppleRevokeWorker) DeliverOne(ctx context.Context) (bool, error) {
	tx, err := w.DB.Begin(ctx)
	if err != nil {
		return false, err
	}
	defer tx.Rollback(ctx)
	var id string
	var ciphertext []byte
	var attempts int
	var expires time.Time
	var deletionJob *string
	err = tx.QueryRow(ctx, `SELECT id::text,payload_ciphertext,attempts,expires_at,deletion_job_id::text FROM outbox_jobs
		WHERE kind='apple_revoke' AND completed_at IS NULL AND (lease_until IS NULL OR lease_until<=now())
		AND (available_at<=now() OR expires_at<=now()) ORDER BY available_at FOR UPDATE SKIP LOCKED LIMIT 1`).
		Scan(&id, &ciphertext, &attempts, &expires, &deletionJob)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	if _, err := tx.Exec(ctx, `UPDATE outbox_jobs SET lease_until=now()+interval '20 seconds' WHERE id=$1`, id); err != nil {
		return false, err
	}
	if err := tx.Commit(ctx); err != nil {
		return false, err
	}
	payloadBytes, err := w.Box.Open(ciphertext, []byte("flowriver-outbox-v1|"+id+"|apple_revoke"))
	if err != nil {
		return true, w.finish(ctx, id, deletionJob, false, true)
	}
	var payload revokePayload
	if json.Unmarshal(payloadBytes, &payload) != nil || payload.ClientID == "" || payload.RefreshToken == "" {
		return true, w.finish(ctx, id, deletionJob, false, true)
	}
	if !expires.After(time.Now()) {
		return true, w.finish(ctx, id, deletionJob, false, true)
	}
	if w.Apple == nil {
		return true, w.retry(ctx, id, attempts, expires, deletionJob)
	}
	if err := w.Apple.Revoke(ctx, payload.ClientID, payload.RefreshToken); err != nil {
		return true, w.retry(ctx, id, attempts, expires, deletionJob)
	}
	return true, w.finish(ctx, id, deletionJob, true, false)
}

func (w *AppleRevokeWorker) retry(ctx context.Context, id string, attempts int, expires time.Time, deletionJob *string) error {
	next := attempts + 1
	delay := time.Duration(math.Min(30*math.Pow(2, float64(next-1)), 300) * float64(time.Second))
	if next >= 8 || !time.Now().Add(delay).Before(expires) {
		return w.finish(ctx, id, deletionJob, false, true)
	}
	_, err := w.DB.Exec(ctx, `UPDATE outbox_jobs SET attempts=$2,available_at=now()+$3::interval,lease_until=NULL,last_error_code='apple_revoke_failed' WHERE id=$1`, id, next, delay.String())
	return err
}

func (w *AppleRevokeWorker) finish(ctx context.Context, id string, deletionJob *string, success, manual bool) error {
	status := "complete"
	if manual {
		status = "manual_action_required"
	}
	tx, err := w.DB.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, `UPDATE outbox_jobs SET completed_at=now(),payload_ciphertext=''::bytea,lease_until=NULL,
		last_error_code=CASE WHEN $2 THEN NULL ELSE 'apple_revoke_failed' END WHERE id=$1`, id, success); err != nil {
		return err
	}
	if deletionJob != nil {
		var pending, failed int
		if err := tx.QueryRow(ctx, `SELECT count(*) FILTER(WHERE completed_at IS NULL),count(*) FILTER(WHERE completed_at IS NOT NULL AND last_error_code IS NOT NULL)
			FROM outbox_jobs WHERE kind='apple_revoke' AND deletion_job_id=$1`, *deletionJob).Scan(&pending, &failed); err != nil {
			return err
		}
		if failed > 0 {
			status = "manual_action_required"
		} else if pending > 0 {
			status = "pending"
		}
		var manual bool
		if err := tx.QueryRow(ctx, `SELECT last_error_code='apple_revoke_manual_action' FROM deletion_jobs WHERE id=$1`, *deletionJob).Scan(&manual); err != nil {
			return err
		}
		if manual {
			status = "manual_action_required"
		}
		if _, err := tx.Exec(ctx, `UPDATE deletion_jobs SET apple_revocation_status=$2 WHERE id=$1`, *deletionJob, status); err != nil {
			return err
		}
	}
	return tx.Commit(ctx)
}
