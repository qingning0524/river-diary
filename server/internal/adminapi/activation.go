package adminapi

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"math/big"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"

	"flowriver/server/internal/secure"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

const activationAlphabet = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ"

var activationCodePattern = regexp.MustCompile(`^[A-Z0-9]{12,32}$`)
var activationProductPattern = regexp.MustCompile(`^[a-z0-9][a-z0-9._-]{0,63}$`)

type activationBatchRequest struct {
	Label        string     `json:"label"`
	ProductCode  string     `json:"product_code"`
	DurationDays int        `json:"duration_days"`
	ExpiresAt    *time.Time `json:"expires_at"`
	Count        int        `json:"count"`
}

type importActivationBatchRequest struct {
	Label        string     `json:"label"`
	ProductCode  string     `json:"product_code"`
	DurationDays int        `json:"duration_days"`
	ExpiresAt    *time.Time `json:"expires_at"`
	Codes        []string   `json:"codes"`
}

type issuedActivationCode struct {
	ID     string `json:"id"`
	Code   string `json:"code"`
	Suffix string `json:"suffix"`
}

func normalizeCode(value string) string {
	value = strings.ToUpper(strings.TrimSpace(value))
	value = strings.ReplaceAll(value, "-", "")
	value = strings.ReplaceAll(value, " ", "")
	return value
}

func formatActivationCode(raw string) string {
	groups := make([]string, 0, 4)
	for i := 0; i < len(raw); i += 4 {
		end := i + 4
		if end > len(raw) {
			end = len(raw)
		}
		groups = append(groups, raw[i:end])
	}
	return "RD-" + strings.Join(groups, "-")
}

func generateActivationCode() (string, error) {
	var raw strings.Builder
	for i := 0; i < 16; i++ {
		n, err := rand.Int(rand.Reader, big.NewInt(int64(len(activationAlphabet))))
		if err != nil {
			return "", err
		}
		raw.WriteByte(activationAlphabet[n.Int64()])
	}
	return raw.String(), nil
}

func (a *API) activationBatches(w http.ResponseWriter, r *http.Request) {
	rows, err := a.db.Query(r.Context(), `SELECT b.id::text,b.label,b.product_code,b.duration_days,b.expires_at,b.created_at,
		count(c.id)::integer,count(c.id) FILTER (WHERE c.redeemed_at IS NOT NULL)::integer,
		count(c.id) FILTER (WHERE c.redeemed_at IS NULL AND c.revoked_at IS NULL AND b.revoked_at IS NULL
			AND (b.expires_at IS NULL OR b.expires_at>now()))::integer,b.revoked_at
		FROM activation_batches b LEFT JOIN activation_codes c ON c.batch_id=b.id
		GROUP BY b.id ORDER BY b.created_at DESC LIMIT 100`)
	if err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	defer rows.Close()
	items := make([]map[string]any, 0)
	for rows.Next() {
		var id, label, product string
		var duration, total, redeemed, unused int
		var expiry *time.Time
		var created time.Time
		var revoked *time.Time
		if err := rows.Scan(&id, &label, &product, &duration, &expiry, &created, &total, &redeemed, &unused, &revoked); err != nil {
			writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
			return
		}
		items = append(items, map[string]any{"id": id, "label": label, "product_code": product, "duration_days": duration,
			"expires_at": expiry, "created_at": created, "total_codes": total, "redeemed_count": redeemed,
			"unused_count": unused, "revoked_at": revoked})
	}
	if err := rows.Err(); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"batches": items})
}

func (a *API) activationCodes(w http.ResponseWriter, r *http.Request) {
	batchID := strings.ToLower(strings.TrimSpace(r.URL.Query().Get("batch_id")))
	if batchID != "" && !isUUID(batchID) {
		writeError(w, apiError{Status: 400, Code: "invalid_batch_id"})
		return
	}
	rows, err := a.db.Query(r.Context(), `SELECT c.id::text,c.batch_id::text,c.code_suffix,c.created_at,c.redeemed_at,
		COALESCE(c.redeemed_user_id::text,''),c.revoked_at,
		CASE WHEN c.revoked_at IS NOT NULL OR b.revoked_at IS NOT NULL THEN 'revoked'
			WHEN c.redeemed_at IS NOT NULL THEN 'redeemed'
			WHEN b.expires_at IS NOT NULL AND b.expires_at<=now() THEN 'expired' ELSE 'unused' END
		FROM activation_codes c JOIN activation_batches b ON b.id=c.batch_id
		WHERE ($1='' OR c.batch_id::text=$1) ORDER BY c.created_at DESC LIMIT 300`, batchID)
	if err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	defer rows.Close()
	items := make([]map[string]any, 0)
	for rows.Next() {
		var id, batch, suffix, status string
		var created time.Time
		var redeemed, revoked *time.Time
		var userID string
		if err := rows.Scan(&id, &batch, &suffix, &created, &redeemed, &userID, &revoked, &status); err != nil {
			writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
			return
		}
		items = append(items, map[string]any{"id": id, "batch_id": batch, "suffix": suffix,
			"created_at": created, "redeemed_at": redeemed, "redeemed_user_id": nullableString(userID),
			"revoked_at": revoked, "status": status})
	}
	if err := rows.Err(); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"codes": items})
}

func nullableString(value string) any {
	if value == "" {
		return nil
	}
	return value
}

func validateActivationBatch(label, product string, duration int, expiry *time.Time) (string, string, error) {
	label = strings.TrimSpace(label)
	if len(label) < 1 || len(label) > 120 || duration < 0 || duration > 36500 {
		return "", "", apiError{Status: 400, Code: "invalid_request"}
	}
	if product == "" {
		product = "riverdiary_premium"
	}
	if !activationProductPattern.MatchString(product) || (expiry != nil && !expiry.After(time.Now())) {
		return "", "", apiError{Status: 400, Code: "invalid_request"}
	}
	return label, product, nil
}

func (a *API) createActivationBatch(w http.ResponseWriter, r *http.Request) {
	var input activationBatchRequest
	if err := decodeJSON(w, r, &input); err != nil {
		writeError(w, err)
		return
	}
	label, product, err := validateActivationBatch(input.Label, input.ProductCode, input.DurationDays, input.ExpiresAt)
	if err != nil || input.Count < 1 || input.Count > 500 {
		writeError(w, apiError{Status: 400, Code: "invalid_request"})
		return
	}
	s := currentSession(r)
	key := strings.TrimSpace(r.Header.Get("Idempotency-Key"))
	if !idempotencyKeyPattern.MatchString(key) {
		writeError(w, apiError{Status: 400, Code: "idempotency_key_required"})
		return
	}
	expiresKey := ""
	if input.ExpiresAt != nil {
		expiresKey = input.ExpiresAt.UTC().Format(time.RFC3339Nano)
	}
	requestMAC := secure.MAC(a.cfg.AdminAuditHMACKey, "admin-activation-batch-v1", label, product,
		strconv.Itoa(input.DurationDays), strconv.Itoa(input.Count), expiresKey)
	keyMAC := secure.Digest(key)
	tx, err := a.db.Begin(r.Context())
	if err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	defer tx.Rollback(r.Context())
	inserted, err := tx.Exec(r.Context(), `INSERT INTO activation_batch_requests(admin_id,key_mac,request_mac,retry_until)
		VALUES($1,$2,$3,now()+interval '15 minutes') ON CONFLICT(admin_id,key_mac) DO NOTHING`, s.AdminID, keyMAC, requestMAC)
	if err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	if inserted.RowsAffected() == 0 {
		var previousMAC, ciphertext []byte
		var retryUntil time.Time
		if err := tx.QueryRow(r.Context(), `SELECT request_mac,response_ciphertext,retry_until FROM activation_batch_requests
			WHERE admin_id=$1 AND key_mac=$2 FOR UPDATE`, s.AdminID, keyMAC).Scan(&previousMAC, &ciphertext, &retryUntil); err != nil {
			writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
			return
		}
		if !secure.EqualMAC(previousMAC, requestMAC) {
			writeError(w, apiError{Status: 409, Code: "idempotency_key_reused"})
			return
		}
		if !retryUntil.After(time.Now()) || len(ciphertext) == 0 {
			writeError(w, apiError{Status: 409, Code: "activation_codes_unavailable"})
			return
		}
		plain, err := a.actionBox.Open(ciphertext, activationOutputAAD(s.AdminID, keyMAC))
		if err != nil {
			writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
			return
		}
		if err := tx.Commit(r.Context()); err != nil {
			writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
			return
		}
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		w.WriteHeader(http.StatusCreated)
		_, _ = w.Write(plain)
		return
	}
	var batchID string
	if err := tx.QueryRow(r.Context(), `INSERT INTO activation_batches(label,product_code,duration_days,expires_at,created_by)
		VALUES($1,$2,$3,$4,$5) RETURNING id::text`, label, product, input.DurationDays, input.ExpiresAt, s.AdminID).Scan(&batchID); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	codes := make([]issuedActivationCode, 0, input.Count)
	for range input.Count {
		raw, err := generateActivationCode()
		if err != nil {
			writeError(w, apiError{Status: 500, Code: "internal_error"})
			return
		}
		displayCode := formatActivationCode(raw)
		canonicalCode := normalizeCode(displayCode)
		id, err := insertActivationCode(r.Context(), tx, a.cfg.AuthHMACKey, batchID, canonicalCode)
		if err != nil {
			writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
			return
		}
		codes = append(codes, issuedActivationCode{ID: id, Code: displayCode, Suffix: raw[len(raw)-4:]})
	}
	if err := a.auditTx(r.Context(), tx, s.AdminID, "admin.activation.batch.create", "activation_batch", batchID, "generated", "success", s.IPMac); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	response, err := json.Marshal(map[string]any{"batch": map[string]any{"id": batchID, "label": label,
		"product_code": product, "duration_days": input.DurationDays, "expires_at": input.ExpiresAt, "total_codes": len(codes)}, "codes": codes})
	if err != nil {
		writeError(w, apiError{Status: 500, Code: "internal_error"})
		return
	}
	ciphertext, err := a.actionBox.Seal(response, activationOutputAAD(s.AdminID, keyMAC))
	if err != nil {
		writeError(w, apiError{Status: 500, Code: "internal_error"})
		return
	}
	if _, err := tx.Exec(r.Context(), `UPDATE activation_batch_requests SET response_ciphertext=$3 WHERE admin_id=$1 AND key_mac=$2`, s.AdminID, keyMAC, ciphertext); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	if err := tx.Commit(r.Context()); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(http.StatusCreated)
	_, _ = w.Write(response)
}

func activationOutputAAD(adminID string, keyMAC []byte) []byte {
	return []byte("flowriver-activation-output-v1|" + adminID + "|" + hex.EncodeToString(keyMAC))
}

func (a *API) importActivationBatch(w http.ResponseWriter, r *http.Request) {
	var input importActivationBatchRequest
	if err := decodeJSON(w, r, &input); err != nil {
		writeError(w, err)
		return
	}
	label, product, err := validateActivationBatch(input.Label, input.ProductCode, input.DurationDays, input.ExpiresAt)
	if err != nil || len(input.Codes) < 1 || len(input.Codes) > 400 {
		writeError(w, apiError{Status: 400, Code: "invalid_request"})
		return
	}
	codes := make([]string, 0, len(input.Codes))
	seen := make(map[string]struct{}, len(input.Codes))
	for _, supplied := range input.Codes {
		code := normalizeCode(supplied)
		if !activationCodePattern.MatchString(code) {
			writeError(w, apiError{Status: 400, Code: "invalid_code_format"})
			return
		}
		if _, exists := seen[code]; exists {
			writeError(w, apiError{Status: 400, Code: "duplicate_code"})
			return
		}
		seen[code] = struct{}{}
		codes = append(codes, code)
	}
	s := currentSession(r)
	tx, err := a.db.Begin(r.Context())
	if err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	defer tx.Rollback(r.Context())
	var batchID string
	if err := tx.QueryRow(r.Context(), `INSERT INTO activation_batches(label,product_code,duration_days,expires_at,created_by)
		VALUES($1,$2,$3,$4,$5) RETURNING id::text`, label, product, input.DurationDays, input.ExpiresAt, s.AdminID).Scan(&batchID); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	for _, code := range codes {
		if _, err := insertActivationCode(r.Context(), tx, a.cfg.AuthHMACKey, batchID, code); err != nil {
			var pgErr *pgconn.PgError
			if errors.As(err, &pgErr) && pgErr.Code == "23505" {
				writeError(w, apiError{Status: 409, Code: "activation_code_exists"})
				return
			}
			writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
			return
		}
	}
	if err := a.auditTx(r.Context(), tx, s.AdminID, "admin.activation.batch.import", "activation_batch", batchID, "imported", "success", s.IPMac); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	if err := tx.Commit(r.Context()); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{"batch": map[string]any{"id": batchID, "label": label,
		"product_code": product, "duration_days": input.DurationDays, "expires_at": input.ExpiresAt, "total_codes": len(codes)}})
}

func insertActivationCode(ctx context.Context, tx pgx.Tx, key []byte, batchID, code string) (string, error) {
	var id string
	mac := secure.MAC(key, "activation-code-v1", code)
	err := tx.QueryRow(ctx, `INSERT INTO activation_codes(batch_id,code_mac,code_suffix)
		VALUES($1,$2,$3) RETURNING id::text`, batchID, mac, code[len(code)-4:]).Scan(&id)
	return id, err
}

func (a *API) revokeActivationCode(w http.ResponseWriter, r *http.Request) {
	codeID := strings.ToLower(r.PathValue("id"))
	if !isUUID(codeID) {
		writeError(w, apiError{Status: 400, Code: "invalid_code_id"})
		return
	}
	s := currentSession(r)
	tx, err := a.db.Begin(r.Context())
	if err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	defer tx.Rollback(r.Context())
	var redeemedAt, revokedAt *time.Time
	err = tx.QueryRow(r.Context(), `SELECT redeemed_at,revoked_at FROM activation_codes WHERE id=$1 FOR UPDATE`, codeID).Scan(&redeemedAt, &revokedAt)
	if err != nil {
		if err == pgx.ErrNoRows {
			writeError(w, apiError{Status: 404, Code: "activation_code_not_found"})
		} else {
			writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		}
		return
	}
	if redeemedAt != nil {
		writeError(w, apiError{Status: 409, Code: "activation_code_already_redeemed"})
		return
	}
	if _, err := tx.Exec(r.Context(), `UPDATE activation_codes SET revoked_at=COALESCE(revoked_at,now()) WHERE id=$1`, codeID); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	if err := a.auditTx(r.Context(), tx, s.AdminID, "admin.activation.code.revoke", "activation_code", codeID, "manual_revoke", "success", s.IPMac); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	if err := tx.Commit(r.Context()); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "revoked", "id": codeID})
}
