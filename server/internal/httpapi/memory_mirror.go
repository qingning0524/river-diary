package httpapi

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

const (
	memoryMirrorFormat        = "river.cloud-mirror"
	memoryMirrorVersion       = 1
	memoryMirrorKDFName       = "PBKDF2-SHA-256"
	memoryMirrorCipherName    = "AES-GCM-256"
	memoryMirrorMinIterations = 100_000
	memoryMirrorMaxIterations = 2_000_000
	memoryMirrorMaxCiphertext = 16 << 20
	memoryMirrorMaxSummary    = 4 << 10
	memoryMirrorMaxEnvelope   = 24 << 20
)

type memoryMirrorKDF struct {
	Name       string `json:"name"`
	Iterations int    `json:"iterations"`
	Salt       string `json:"salt"`
}

type memoryMirrorCipher struct {
	Name string `json:"name"`
	IV   string `json:"iv"`
}

type memoryMirrorUpload struct {
	Format          string             `json:"format"`
	Version         int                `json:"version"`
	KDF             memoryMirrorKDF    `json:"kdf"`
	Cipher          memoryMirrorCipher `json:"cipher"`
	Ciphertext      string             `json:"ciphertext"`
	ClientUpdatedAt string             `json:"client_updated_at"`
	Summary         json.RawMessage    `json:"summary"`
}

type memoryMirrorMeta struct {
	Exists          bool                `json:"exists"`
	Revision        int64               `json:"revision,omitempty"`
	SizeBytes       int                 `json:"size_bytes,omitempty"`
	Format          string              `json:"format,omitempty"`
	Version         int                 `json:"version,omitempty"`
	KDF             *memoryMirrorKDF    `json:"kdf,omitempty"`
	Cipher          *memoryMirrorCipher `json:"cipher,omitempty"`
	ClientUpdatedAt *time.Time          `json:"client_updated_at,omitempty"`
	Summary         json.RawMessage     `json:"summary,omitempty"`
	CreatedAt       *time.Time          `json:"created_at,omitempty"`
	UpdatedAt       *time.Time          `json:"updated_at,omitempty"`
	Ciphertext      string              `json:"ciphertext,omitempty"`
}

type mirrorRowQuerier interface {
	QueryRow(context.Context, string, ...any) pgx.Row
}

func mirrorPrecondition(r *http.Request, requireMatch bool) (ifNone bool, expected int64, err error) {
	none := strings.TrimSpace(r.Header.Get("If-None-Match"))
	match := strings.TrimSpace(r.Header.Get("If-Match"))
	if none != "" && none != "*" {
		return false, 0, apiError{Status: 400, Code: "invalid_request"}
	}
	if none != "" && match != "" {
		return false, 0, apiError{Status: 400, Code: "invalid_request"}
	}
	if requireMatch && none != "" {
		return false, 0, apiError{Status: 400, Code: "invalid_request"}
	}
	if match != "" {
		match = strings.Trim(match, "\"")
		value, parseErr := strconv.ParseInt(match, 10, 64)
		if parseErr != nil || value < 1 {
			return false, 0, apiError{Status: 400, Code: "invalid_request"}
		}
		expected = value
	}
	if requireMatch && match == "" {
		return false, 0, apiError{Status: 428, Code: "precondition_required"}
	}
	if !requireMatch && none == "" && match == "" {
		return false, 0, apiError{Status: 428, Code: "precondition_required"}
	}
	return none == "*", expected, nil
}

func (a *API) mirrorRateLimit(ctx context.Context, userID, action string, limit int, period time.Duration) error {
	tx, err := a.db.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	count, err := a.hitRateLimit(ctx, tx, "memory-mirror-"+action+":"+userID, limit, period)
	if err != nil {
		return err
	}
	if count > limit {
		if err = tx.Commit(ctx); err != nil {
			return err
		}
		return apiError{Status: 429, Code: "rate_limited"}
	}
	return tx.Commit(ctx)
}

func (a *API) mirrorRateFailure(w http.ResponseWriter, r *http.Request, err error, operation string) {
	var problem apiError
	if errors.As(err, &problem) {
		writeError(w, r, problem)
		return
	}
	a.databaseFailure(w, r, operation)
}

func decodeMirrorBytes(value string, size int) ([]byte, error) {
	decoded, err := base64.StdEncoding.DecodeString(value)
	if err != nil || len(decoded) != size {
		return nil, apiError{Status: 400, Code: "invalid_request"}
	}
	return decoded, nil
}

type memoryMirrorSummary struct {
	Entries        int    `json:"entries"`
	Days           int    `json:"days"`
	Places         int    `json:"places"`
	Collections    int    `json:"collections"`
	Understandings int    `json:"understandings"`
	First          string `json:"first"`
	Last           string `json:"last"`
	// IncludesHealth is client-declared metadata for an explicitly consented
	// snapshot. The server cannot verify it because it only sees ciphertext;
	// consumers must treat false as "not declared" rather than as a guarantee.
	IncludesHealth bool `json:"includes_health"`
}

func normalizeMirrorSummary(raw json.RawMessage) ([]byte, error) {
	if len(raw) == 0 {
		return []byte("{}"), nil
	}
	if len(raw) > memoryMirrorMaxSummary {
		return nil, apiError{Status: 400, Code: "invalid_request"}
	}
	var summary memoryMirrorSummary
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&summary); err != nil {
		return nil, apiError{Status: 400, Code: "invalid_request"}
	}
	if summary.Entries < 0 || summary.Entries > 1000000 || summary.Days < 0 || summary.Days > 1000000 ||
		summary.Places < 0 || summary.Places > 1000000 || summary.Collections < 0 || summary.Collections > 1000000 ||
		summary.Understandings < 0 || summary.Understandings > 1000000 {
		return nil, apiError{Status: 400, Code: "invalid_request"}
	}
	for _, date := range []string{summary.First, summary.Last} {
		if date == "" {
			continue
		}
		if len(date) != 10 {
			return nil, apiError{Status: 400, Code: "invalid_request"}
		}
		if _, err := time.Parse("2006-01-02", date); err != nil {
			return nil, apiError{Status: 400, Code: "invalid_request"}
		}
	}
	encoded, err := json.Marshal(summary)
	if err != nil {
		return nil, apiError{Status: 400, Code: "invalid_request"}
	}
	return encoded, nil
}

func validateMirrorUpload(input *memoryMirrorUpload) (salt, iv, ciphertext, summary []byte, clientUpdated *time.Time, err error) {
	if input.Format != memoryMirrorFormat || input.Version != memoryMirrorVersion ||
		input.KDF.Name != memoryMirrorKDFName || input.Cipher.Name != memoryMirrorCipherName ||
		input.KDF.Iterations < memoryMirrorMinIterations || input.KDF.Iterations > memoryMirrorMaxIterations {
		err = apiError{Status: 400, Code: "invalid_request"}
		return
	}
	if salt, err = decodeMirrorBytes(input.KDF.Salt, 16); err != nil {
		return
	}
	if iv, err = decodeMirrorBytes(input.Cipher.IV, 12); err != nil {
		return
	}
	ciphertext, err = base64.StdEncoding.DecodeString(input.Ciphertext)
	if err != nil || len(ciphertext) == 0 {
		err = apiError{Status: 400, Code: "invalid_request"}
		return
	}
	if len(ciphertext) > memoryMirrorMaxCiphertext {
		err = apiError{Status: 413, Code: "request_too_large"}
		return
	}
	summary, err = normalizeMirrorSummary(input.Summary)
	if err != nil {
		return
	}
	if raw := strings.TrimSpace(input.ClientUpdatedAt); raw != "" {
		parsed, parseErr := time.Parse(time.RFC3339, raw)
		if parseErr != nil {
			err = apiError{Status: 400, Code: "invalid_request"}
			return
		}
		clientUpdated = &parsed
	}
	return
}

func (a *API) memoryMirrorMeta(w http.ResponseWriter, r *http.Request) {
	ctx, p, err := a.authenticate(r)
	if err != nil {
		writeError(w, r, err)
		return
	}
	if err = a.mirrorRateLimit(ctx, p.UserID, "meta", 240, time.Hour); err != nil {
		a.mirrorRateFailure(w, r, err, "memory_mirror_meta_rate")
		return
	}
	meta, err := a.readMemoryMirrorMeta(ctx, a.db, p.UserID, false)
	if errors.Is(err, pgx.ErrNoRows) {
		writeJSON(w, http.StatusOK, memoryMirrorMeta{Exists: false})
		return
	}
	if err != nil {
		a.databaseFailure(w, r, "memory_mirror_meta")
		return
	}
	writeJSON(w, http.StatusOK, meta)
}

func (a *API) memoryMirrorDownload(w http.ResponseWriter, r *http.Request) {
	ctx, p, err := a.authenticate(r)
	if err != nil {
		writeError(w, r, err)
		return
	}
	if err = a.mirrorRateLimit(ctx, p.UserID, "download", 120, time.Hour); err != nil {
		a.mirrorRateFailure(w, r, err, "memory_mirror_download_rate")
		return
	}
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	tx, err := a.db.Begin(ctx)
	if err != nil {
		a.databaseFailure(w, r, "memory_mirror_download_begin")
		return
	}
	defer tx.Rollback(ctx)
	meta, err := a.readMemoryMirrorMeta(ctx, tx, p.UserID, true)
	if errors.Is(err, pgx.ErrNoRows) {
		writeError(w, r, apiError{Status: 404, Code: "mirror_not_found"})
		return
	}
	if err != nil {
		a.databaseFailure(w, r, "memory_mirror_download_read")
		return
	}
	if err = audit(ctx, tx, p.UserID, "memory_mirror_downloaded", requestIDFromContext(ctx)); err != nil {
		a.databaseFailure(w, r, "memory_mirror_download_audit")
		return
	}
	if err = tx.Commit(ctx); err != nil {
		a.databaseFailure(w, r, "memory_mirror_download_commit")
		return
	}
	meta.Exists = true
	writeJSON(w, http.StatusOK, meta)
}

func (a *API) memoryMirrorUpload(w http.ResponseWriter, r *http.Request) {
	ctx, p, err := a.authenticate(r)
	if err != nil {
		writeError(w, r, err)
		return
	}
	if err = a.mirrorRateLimit(ctx, p.UserID, "upload", 20, time.Hour); err != nil {
		a.mirrorRateFailure(w, r, err, "memory_mirror_upload_rate")
		return
	}
	ifNone, expected, err := mirrorPrecondition(r, false)
	if err != nil {
		writeError(w, r, err)
		return
	}
	var input memoryMirrorUpload
	if err = decodeJSON(w, r, &input); err != nil {
		writeError(w, r, err)
		return
	}
	salt, iv, ciphertext, summary, clientUpdated, err := validateMirrorUpload(&input)
	if err != nil {
		writeError(w, r, err)
		return
	}
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	tx, err := a.db.Begin(ctx)
	if err != nil {
		a.databaseFailure(w, r, "memory_mirror_upload_begin")
		return
	}
	defer tx.Rollback(ctx)
	var current int64
	err = tx.QueryRow(ctx, `SELECT revision FROM user_memory_mirrors WHERE user_id=$1 FOR UPDATE`, p.UserID).Scan(&current)
	var revision int64
	var createdAt, updatedAt time.Time
	status := http.StatusOK
	if errors.Is(err, pgx.ErrNoRows) {
		if !ifNone {
			writeError(w, r, apiError{Status: 404, Code: "mirror_not_found"})
			return
		}
		err = tx.QueryRow(ctx, `INSERT INTO user_memory_mirrors
			(user_id,format,format_version,kdf_name,kdf_iterations,kdf_salt,cipher_name,cipher_iv,ciphertext,client_updated_at,summary)
			VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11) RETURNING revision,created_at,updated_at`,
			p.UserID, memoryMirrorFormat, memoryMirrorVersion, memoryMirrorKDFName, input.KDF.Iterations, salt,
			memoryMirrorCipherName, iv, ciphertext, clientUpdated, summary).Scan(&revision, &createdAt, &updatedAt)
		if err != nil {
			var pgErr *pgconn.PgError
			if errors.As(err, &pgErr) && pgErr.Code == "23505" {
				writeError(w, r, apiError{Status: 409, Code: "mirror_exists"})
				return
			}
			a.databaseFailure(w, r, "memory_mirror_insert")
			return
		}
		status = http.StatusCreated
	} else if err != nil {
		a.databaseFailure(w, r, "memory_mirror_lock")
		return
	} else {
		if ifNone {
			writeError(w, r, apiError{Status: 409, Code: "mirror_exists"})
			return
		}
		if expected != current {
			writeError(w, r, apiError{Status: 412, Code: "mirror_conflict"})
			return
		}
		err = tx.QueryRow(ctx, `UPDATE user_memory_mirrors SET revision=revision+1,format=$2,format_version=$3,
			kdf_name=$4,kdf_iterations=$5,kdf_salt=$6,cipher_name=$7,cipher_iv=$8,ciphertext=$9,
			client_updated_at=$10,summary=$11,updated_at=now()
			WHERE user_id=$1 AND revision=$12 RETURNING revision,created_at,updated_at`,
			p.UserID, memoryMirrorFormat, memoryMirrorVersion, memoryMirrorKDFName, input.KDF.Iterations, salt,
			memoryMirrorCipherName, iv, ciphertext, clientUpdated, summary, current).Scan(&revision, &createdAt, &updatedAt)
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				writeError(w, r, apiError{Status: 412, Code: "mirror_conflict"})
				return
			}
			a.databaseFailure(w, r, "memory_mirror_update")
			return
		}
	}
	if err = audit(ctx, tx, p.UserID, "memory_mirror_uploaded", requestIDFromContext(ctx)); err != nil {
		a.databaseFailure(w, r, "memory_mirror_upload_audit")
		return
	}
	if err = tx.Commit(ctx); err != nil {
		a.databaseFailure(w, r, "memory_mirror_upload_commit")
		return
	}
	writeJSON(w, status, memoryMirrorMeta{
		Exists: true, Revision: revision, SizeBytes: len(ciphertext), Format: memoryMirrorFormat,
		Version:         memoryMirrorVersion,
		KDF:             &memoryMirrorKDF{Name: memoryMirrorKDFName, Iterations: input.KDF.Iterations, Salt: input.KDF.Salt},
		Cipher:          &memoryMirrorCipher{Name: memoryMirrorCipherName, IV: input.Cipher.IV},
		ClientUpdatedAt: clientUpdated, Summary: json.RawMessage(summary),
		CreatedAt: &createdAt, UpdatedAt: &updatedAt,
	})
}

func (a *API) memoryMirrorDelete(w http.ResponseWriter, r *http.Request) {
	ctx, p, err := a.authenticate(r)
	if err != nil {
		writeError(w, r, err)
		return
	}
	if err = a.mirrorRateLimit(ctx, p.UserID, "delete", 30, time.Hour); err != nil {
		a.mirrorRateFailure(w, r, err, "memory_mirror_delete_rate")
		return
	}
	_, expected, err := mirrorPrecondition(r, true)
	if err != nil {
		writeError(w, r, err)
		return
	}
	tx, err := a.db.Begin(ctx)
	if err != nil {
		a.databaseFailure(w, r, "memory_mirror_delete_begin")
		return
	}
	defer tx.Rollback(ctx)
	tag, err := tx.Exec(ctx, `DELETE FROM user_memory_mirrors WHERE user_id=$1 AND revision=$2`, p.UserID, expected)
	if err != nil {
		a.databaseFailure(w, r, "memory_mirror_delete")
		return
	}
	if tag.RowsAffected() == 0 {
		var exists bool
		if err = tx.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM user_memory_mirrors WHERE user_id=$1)`, p.UserID).Scan(&exists); err != nil {
			a.databaseFailure(w, r, "memory_mirror_delete_check")
			return
		}
		if !exists {
			writeError(w, r, apiError{Status: 404, Code: "mirror_not_found"})
			return
		}
		writeError(w, r, apiError{Status: 412, Code: "mirror_conflict"})
		return
	}
	if err = audit(ctx, tx, p.UserID, "memory_mirror_deleted", requestIDFromContext(ctx)); err != nil {
		a.databaseFailure(w, r, "memory_mirror_delete_audit")
		return
	}
	if err = tx.Commit(ctx); err != nil {
		a.databaseFailure(w, r, "memory_mirror_delete_commit")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (a *API) readMemoryMirrorMeta(ctx context.Context, q mirrorRowQuerier, userID string, withCiphertext bool) (memoryMirrorMeta, error) {
	meta := memoryMirrorMeta{KDF: &memoryMirrorKDF{}, Cipher: &memoryMirrorCipher{}}
	var (
		salt, iv     []byte
		ciphertext   []byte
		summary      []byte
		clientUpdate *time.Time
		created      time.Time
		updated      time.Time
	)
	query := `SELECT revision,format,format_version,kdf_name,kdf_iterations,kdf_salt,cipher_name,cipher_iv,
		octet_length(ciphertext),client_updated_at,summary,created_at,updated_at`
	args := []any{userID}
	if withCiphertext {
		query += `,ciphertext FROM user_memory_mirrors WHERE user_id=$1`
	} else {
		query += ` FROM user_memory_mirrors WHERE user_id=$1`
	}
	dest := []any{&meta.Revision, &meta.Format, &meta.Version, &meta.KDF.Name, &meta.KDF.Iterations, &salt,
		&meta.Cipher.Name, &iv, &meta.SizeBytes, &clientUpdate, &summary, &created, &updated}
	if withCiphertext {
		dest = append(dest, &ciphertext)
	}
	err := q.QueryRow(ctx, query, args...).Scan(dest...)
	if err != nil {
		return memoryMirrorMeta{}, err
	}
	meta.Exists = true
	meta.KDF.Salt = base64.StdEncoding.EncodeToString(salt)
	meta.Cipher.IV = base64.StdEncoding.EncodeToString(iv)
	meta.ClientUpdatedAt = clientUpdate
	meta.CreatedAt = &created
	meta.UpdatedAt = &updated
	meta.Summary = json.RawMessage(summary)
	if withCiphertext {
		meta.Ciphertext = base64.StdEncoding.EncodeToString(ciphertext)
	}
	return meta, nil
}
