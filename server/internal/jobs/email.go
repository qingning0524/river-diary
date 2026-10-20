package jobs

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"math"
	"time"

	"flowriver/server/internal/mailer"
	"flowriver/server/internal/secure"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type EmailWorker struct {
	DB     *pgxpool.Pool
	Box    *secure.Box
	Sender mailer.Sender
	Log    *slog.Logger
}

type otpPayload struct {
	To          string `json:"to"`
	Code        string `json:"code"`
	ChallengeID string `json:"challenge_id"`
}

func (w *EmailWorker) Run(ctx context.Context) {
	ticker := time.NewTicker(1200 * time.Millisecond)
	defer ticker.Stop()
	nextCleanup := time.Now()
	for {
		worked, err := w.DeliverOne(ctx)
		if err != nil && ctx.Err() == nil {
			w.Log.Error("email outbox worker failed", "error_code", "outbox_database_error")
		}
		if worked {
			continue
		}
		if time.Now().After(nextCleanup) {
			if err := w.Cleanup(ctx); err != nil && ctx.Err() == nil {
				w.Log.Error("outbox cleanup failed", "error_code", "cleanup_database_error")
			}
			nextCleanup = time.Now().Add(5 * time.Minute)
		}
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}

func (w *EmailWorker) DeliverOne(ctx context.Context) (bool, error) {
	tx, err := w.DB.Begin(ctx)
	if err != nil {
		return false, err
	}
	defer tx.Rollback(ctx)

	var id, kind string
	var payloadCiphertext []byte
	var attempts int
	err = tx.QueryRow(ctx, `
		SELECT id::text, kind, payload_ciphertext, attempts
		FROM outbox_jobs
		WHERE kind='email_otp' AND completed_at IS NULL AND (lease_until IS NULL OR lease_until <= now())
		  AND (available_at <= now() OR expires_at <= now())
		ORDER BY available_at, created_at
		FOR UPDATE SKIP LOCKED LIMIT 1`).Scan(&id, &kind, &payloadCiphertext, &attempts)
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

	var expiresAt time.Time
	if err := w.DB.QueryRow(ctx, `SELECT expires_at FROM outbox_jobs WHERE id=$1`, id).Scan(&expiresAt); err != nil {
		return true, err
	}
	if !expiresAt.After(time.Now()) {
		return true, w.finish(ctx, id, "job_expired")
	}
	if kind != "email_otp" {
		return true, w.finish(ctx, id, "unsupported_job")
	}
	payload, err := w.Box.Open(payloadCiphertext, []byte("flowriver-outbox-v1|"+id+"|"+kind))
	if err != nil {
		return true, w.finish(ctx, id, "payload_decryption_failed")
	}
	var data otpPayload
	if err := json.Unmarshal(payload, &data); err != nil || data.To == "" || len(data.Code) != 8 || data.ChallengeID == "" {
		return true, w.finish(ctx, id, "payload_invalid")
	}
	var challengeActive bool
	if err := w.DB.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM auth_challenges WHERE id=$1 AND purpose IN ('email_login','email_reauth','email_link','password_reset') AND consumed_at IS NULL AND expires_at>now())`, data.ChallengeID).Scan(&challengeActive); err != nil {
		return true, err
	}
	if !challengeActive {
		return true, w.finish(ctx, id, "challenge_inactive")
	}
	if err := w.Sender.SendOTP(ctx, data.To, data.Code); err != nil {
		if errors.Is(err, mailer.ErrDeliveryUnconfirmed) {
			return true, w.finish(ctx, id, "email_delivery_unconfirmed")
		}
		return true, w.retry(ctx, id, attempts, expiresAt)
	}
	return true, w.finish(ctx, id, "")
}

func (w *EmailWorker) finish(ctx context.Context, id, code string) error {
	_, err := w.DB.Exec(ctx, `UPDATE outbox_jobs
		SET completed_at=now(), payload_ciphertext=''::bytea, lease_until=NULL, last_error_code=NULLIF($2,'')
		WHERE id=$1`, id, code)
	return err
}

func (w *EmailWorker) retry(ctx context.Context, id string, attempts int, expiry time.Time) error {
	nextAttempt := attempts + 1
	if nextAttempt >= 8 || !time.Now().Add(backoff(nextAttempt)).Before(expiry) {
		return w.finish(ctx, id, "email_delivery_failed")
	}
	_, err := w.DB.Exec(ctx, `UPDATE outbox_jobs
		SET attempts=$2, available_at=now()+$3::interval, lease_until=NULL, last_error_code='email_delivery_failed'
		WHERE id=$1`, id, nextAttempt, fmt.Sprintf("%f seconds", backoff(nextAttempt).Seconds()))
	return err
}

func backoff(attempt int) time.Duration {
	seconds := math.Min(30*math.Pow(2, float64(attempt-1)), 300)
	return time.Duration(seconds * float64(time.Second))
}

func (w *EmailWorker) Cleanup(ctx context.Context) error {
	statements := []string{
		`UPDATE refresh_tokens SET response_ciphertext=NULL WHERE retry_until<=now() AND response_ciphertext IS NOT NULL`,
		`DELETE FROM idempotency_results WHERE expires_at<=now()`,
		`DELETE FROM reauth_proofs WHERE expires_at<=now() OR used_at<now()-interval '1 day'`,
		`DELETE FROM auth_challenges WHERE expires_at<now()-interval '1 hour'`,
		`DELETE FROM rate_limit_buckets WHERE expires_at<=now()`,
		`DELETE FROM activation_batch_requests WHERE retry_until<=now()`,
		`DELETE FROM sessions WHERE absolute_expires_at<now() OR (status='revoked' AND revoked_at<now()-interval '30 days')`,
		`DELETE FROM outbox_jobs WHERE (kind='email_otp' AND completed_at<now()-interval '30 days') OR (kind<>'email_otp' AND completed_at<now()-interval '1 hour') OR (expires_at<now()-interval '1 day' AND completed_at IS NULL AND kind='email_otp')`,
		`DELETE FROM audit_events WHERE created_at<now()-interval '30 days'`,
		`DELETE FROM provider_events WHERE received_at<now()-interval '30 days' AND processed_at IS NOT NULL`,
		`DELETE FROM security_event_outbox WHERE delivered_at<now()-interval '30 days'`,
		`DELETE FROM deletion_jobs WHERE status_expires_at<now()-interval '30 days' AND completed_at IS NOT NULL`,
	}
	for _, statement := range statements {
		if _, err := w.DB.Exec(ctx, statement); err != nil {
			return err
		}
	}
	return nil
}
