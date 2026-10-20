package httpapi

import (
	"context"
	"database/sql"
	"errors"
	"time"

	"flowriver/server/internal/secure"
	"github.com/jackc/pgx/v5"
)

func (a *API) cachedResponse(ctx context.Context, tx pgx.Tx, scope, key string, requestMAC []byte) ([]byte, bool, error) {
	var savedMAC, ciphertext []byte
	err := tx.QueryRow(ctx, `SELECT request_mac,response_ciphertext FROM idempotency_results
		WHERE scope=$1 AND request_id=$2 AND expires_at>now() FOR UPDATE`, scope, key).Scan(&savedMAC, &ciphertext)
	if errors.Is(err, pgx.ErrNoRows) || errors.Is(err, sql.ErrNoRows) {
		return nil, false, nil
	}
	if err != nil {
		return nil, false, err
	}
	if !secure.EqualMAC(savedMAC, requestMAC) {
		return nil, true, apiError{Status: 409, Code: "idempotency_conflict"}
	}
	plain, err := a.resultBox.Open(ciphertext, []byte(scope+"|"+key))
	if err != nil {
		return nil, true, err
	}
	return plain, true, nil
}

func (a *API) saveResponse(ctx context.Context, tx pgx.Tx, scope, key string, requestMAC, response []byte) error {
	return a.saveResponseDuration(ctx, tx, scope, key, requestMAC, response, time.Minute)
}
func (a *API) saveResponseDuration(ctx context.Context, tx pgx.Tx, scope, key string, requestMAC, response []byte, ttl time.Duration) error {
	ciphertext, err := a.resultBox.Seal(response, []byte(scope+"|"+key))
	if err != nil {
		return err
	}
	result, err := tx.Exec(ctx, `INSERT INTO idempotency_results(scope,request_id,request_mac,response_ciphertext,expires_at)
		VALUES($1,$2,$3,$4,$5)
		ON CONFLICT(scope,request_id) DO UPDATE SET request_mac=EXCLUDED.request_mac,
		 response_ciphertext=EXCLUDED.response_ciphertext,created_at=now(),expires_at=EXCLUDED.expires_at
		WHERE idempotency_results.expires_at<=now()`, scope, key, requestMAC, ciphertext, time.Now().Add(ttl))
	if err != nil {
		return err
	}
	if result.RowsAffected() != 1 {
		return apiError{Status: 409, Code: "idempotency_conflict"}
	}
	return nil
}
