package adminapi

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"mime"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"
)

// ---- 公告管理 ----

var announcementLevelPattern = regexp.MustCompile(`^(info|warn|critical)$`)
var announcementPlacementPattern = regexp.MustCompile(`^(banner|download|both)$`)

type announcementPayload struct {
	Level     string     `json:"level"`
	Title     string     `json:"title"`
	Body      string     `json:"body"`
	Placement string     `json:"placement"`
	Href      string     `json:"href"`
	Active    bool       `json:"active"`
	StartsAt  *time.Time `json:"starts_at"`
	EndsAt    *time.Time `json:"ends_at"`
}

func (p *announcementPayload) validate() bool {
	if !announcementLevelPattern.MatchString(p.Level) || !announcementPlacementPattern.MatchString(p.Placement) {
		return false
	}
	p.Title = strings.TrimSpace(p.Title)
	p.Body = strings.TrimSpace(p.Body)
	p.Href = strings.TrimSpace(p.Href)
	if utf8.RuneCountInString(p.Title) < 1 || utf8.RuneCountInString(p.Title) > 120 || utf8.RuneCountInString(p.Body) > 500 {
		return false
	}
	if !validAnnouncementHref(p.Href) {
		return false
	}
	if p.StartsAt != nil && p.EndsAt != nil && !p.StartsAt.Before(*p.EndsAt) {
		return false
	}
	return true
}

func validAnnouncementHref(href string) bool {
	if href == "" {
		return true
	}
	if utf8.RuneCountInString(href) > 300 || strings.Contains(href, `\`) || strings.HasPrefix(href, "//") || strings.ContainsFunc(href, func(r rune) bool { return unicode.IsControl(r) || unicode.IsSpace(r) }) {
		return false
	}
	u, err := url.Parse(href)
	if err != nil || u.User != nil || u.Opaque != "" {
		return false
	}
	if u.Scheme == "" {
		return u.Host == ""
	}
	scheme := strings.ToLower(u.Scheme)
	return (scheme == "http" || scheme == "https") && u.Hostname() != ""
}

func (a *API) listAnnouncements(w http.ResponseWriter, r *http.Request) {
	rows, err := a.db.Query(r.Context(), `SELECT a.id::text,a.level,a.title,a.body,a.placement,a.href,a.active,a.starts_at,a.ends_at,a.created_at,a.updated_at,COALESCE(u.username,'')
		FROM announcements a LEFT JOIN admin_accounts u ON u.id=a.created_by
		ORDER BY a.created_at DESC LIMIT 200`)
	if err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	defer rows.Close()
	type item struct {
		ID        string     `json:"id"`
		Level     string     `json:"level"`
		Title     string     `json:"title"`
		Body      string     `json:"body"`
		Placement string     `json:"placement"`
		Href      string     `json:"href"`
		Active    bool       `json:"active"`
		StartsAt  *time.Time `json:"starts_at"`
		EndsAt    *time.Time `json:"ends_at"`
		CreatedAt time.Time  `json:"created_at"`
		UpdatedAt time.Time  `json:"updated_at"`
		CreatedBy string     `json:"created_by"`
	}
	items := make([]item, 0)
	for rows.Next() {
		var it item
		if err := rows.Scan(&it.ID, &it.Level, &it.Title, &it.Body, &it.Placement, &it.Href, &it.Active, &it.StartsAt, &it.EndsAt, &it.CreatedAt, &it.UpdatedAt, &it.CreatedBy); err != nil {
			writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
			return
		}
		items = append(items, it)
	}
	if err := rows.Err(); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"announcements": items})
}

func (a *API) createAnnouncement(w http.ResponseWriter, r *http.Request) {
	var input announcementPayload
	if err := decodeJSON(w, r, &input); err != nil {
		writeError(w, err)
		return
	}
	if !input.validate() {
		writeError(w, apiError{Status: 400, Code: "invalid_request"})
		return
	}
	s := currentSession(r)
	tx, err := a.db.Begin(r.Context())
	if err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	defer tx.Rollback(r.Context())
	var id string
	if err := tx.QueryRow(r.Context(), `INSERT INTO announcements(level,title,body,placement,href,active,starts_at,ends_at,created_by)
		VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9) RETURNING id::text`,
		input.Level, input.Title, input.Body, input.Placement, input.Href, input.Active, input.StartsAt, input.EndsAt, s.AdminID).Scan(&id); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	if err := a.auditTx(r.Context(), tx, s.AdminID, "admin.announcement.create", "announcement", id, input.Placement, "success", s.IPMac); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	if err := tx.Commit(r.Context()); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{"id": id, "status": "created"})
}

func (a *API) updateAnnouncement(w http.ResponseWriter, r *http.Request) {
	id := strings.ToLower(r.PathValue("id"))
	if !isUUID(id) {
		writeError(w, apiError{Status: 400, Code: "invalid_request"})
		return
	}
	var input announcementPayload
	if err := decodeJSON(w, r, &input); err != nil {
		writeError(w, err)
		return
	}
	if !input.validate() {
		writeError(w, apiError{Status: 400, Code: "invalid_request"})
		return
	}
	s := currentSession(r)
	tx, err := a.db.Begin(r.Context())
	if err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	defer tx.Rollback(r.Context())
	tag, err := tx.Exec(r.Context(), `UPDATE announcements SET level=$2,title=$3,body=$4,placement=$5,href=$6,active=$7,starts_at=$8,ends_at=$9,updated_at=now() WHERE id=$1`,
		id, input.Level, input.Title, input.Body, input.Placement, input.Href, input.Active, input.StartsAt, input.EndsAt)
	if err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	if tag.RowsAffected() == 0 {
		writeError(w, apiError{Status: 404, Code: "announcement_not_found"})
		return
	}
	if err := a.auditTx(r.Context(), tx, s.AdminID, "admin.announcement.update", "announcement", id, input.Placement, "success", s.IPMac); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	if err := tx.Commit(r.Context()); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"id": id, "status": "updated"})
}

func (a *API) activateAnnouncement(active bool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		id := strings.ToLower(r.PathValue("id"))
		if !isUUID(id) {
			writeError(w, apiError{Status: 400, Code: "invalid_request"})
			return
		}
		s := currentSession(r)
		tx, err := a.db.Begin(r.Context())
		if err != nil {
			writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
			return
		}
		defer tx.Rollback(r.Context())
		tag, err := tx.Exec(r.Context(), `UPDATE announcements SET active=$2,updated_at=now() WHERE id=$1`, id, active)
		if err != nil {
			writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
			return
		}
		if tag.RowsAffected() == 0 {
			writeError(w, apiError{Status: 404, Code: "announcement_not_found"})
			return
		}
		action := "admin.announcement.deactivate"
		if active {
			action = "admin.announcement.activate"
		}
		if err := a.auditTx(r.Context(), tx, s.AdminID, action, "announcement", id, "", "success", s.IPMac); err != nil {
			writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
			return
		}
		if err := tx.Commit(r.Context()); err != nil {
			writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"id": id, "active": active})
	}
}

func (a *API) deleteAnnouncement(w http.ResponseWriter, r *http.Request) {
	id := strings.ToLower(r.PathValue("id"))
	if !isUUID(id) {
		writeError(w, apiError{Status: 400, Code: "invalid_request"})
		return
	}
	s := currentSession(r)
	tx, err := a.db.Begin(r.Context())
	if err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	defer tx.Rollback(r.Context())
	tag, err := tx.Exec(r.Context(), `DELETE FROM announcements WHERE id=$1`, id)
	if err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	if tag.RowsAffected() == 0 {
		writeError(w, apiError{Status: 404, Code: "announcement_not_found"})
		return
	}
	if err := a.auditTx(r.Context(), tx, s.AdminID, "admin.announcement.delete", "announcement", id, "", "success", s.IPMac); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	if err := tx.Commit(r.Context()); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"id": id, "status": "deleted"})
}

// ---- 下载管理 ----

const maxDownloadBytes = 256 << 20

var downloadFilenamePattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,180}\.zip$`)

func (a *API) listDownloads(w http.ResponseWriter, r *http.Request) {
	rows, err := a.db.Query(r.Context(), `SELECT d.id::text,d.platform,d.version,d.filename,d.size_bytes,d.sha256,d.note,d.is_active,d.created_at,d.activated_at,COALESCE(u.username,'')
		FROM download_artifacts d LEFT JOIN admin_accounts u ON u.id=d.created_by
		ORDER BY d.created_at DESC LIMIT 100`)
	if err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	defer rows.Close()
	type item struct {
		ID          string     `json:"id"`
		Platform    string     `json:"platform"`
		Version     string     `json:"version"`
		Filename    string     `json:"filename"`
		SizeBytes   int64      `json:"size_bytes"`
		SHA256      string     `json:"sha256"`
		Note        string     `json:"note"`
		IsActive    bool       `json:"is_active"`
		CreatedAt   time.Time  `json:"created_at"`
		ActivatedAt *time.Time `json:"activated_at"`
		CreatedBy   string     `json:"created_by"`
	}
	items := make([]item, 0)
	for rows.Next() {
		var it item
		if err := rows.Scan(&it.ID, &it.Platform, &it.Version, &it.Filename, &it.SizeBytes, &it.SHA256, &it.Note, &it.IsActive, &it.CreatedAt, &it.ActivatedAt, &it.CreatedBy); err != nil {
			writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
			return
		}
		items = append(items, it)
	}
	if err := rows.Err(); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"downloads": items, "storage_configured": a.cfg.DownloadDir != ""})
}

func sanitizeDownloadName(name string) (string, bool) {
	name = filepath.Base(strings.TrimSpace(name))
	name = strings.ReplaceAll(name, " ", "-")
	if !downloadFilenamePattern.MatchString(name) || strings.Contains(name, "..") {
		return "", false
	}
	return name, true
}

// uploadDownload streams a multipart upload to DOWNLOAD_DIR and records the
// artifact. The file is written to a temp path first and published atomically.
func (a *API) uploadDownload(w http.ResponseWriter, r *http.Request) {
	if a.cfg.DownloadDir == "" {
		writeError(w, apiError{Status: 503, Code: "download_storage_not_configured"})
		return
	}
	mediaType, params, err := mime.ParseMediaType(r.Header.Get("Content-Type"))
	if err != nil || mediaType != "multipart/form-data" || params["boundary"] == "" {
		writeError(w, apiError{Status: 400, Code: "invalid_request"})
		return
	}
	// Session, CSRF and recent MFA have already been verified by the route.
	// Extend only this multipart installation upload, with a fixed upper bound.
	controller := http.NewResponseController(w)
	deadline := time.Now().Add(10 * time.Minute)
	for _, setDeadline := range []func(time.Time) error{controller.SetReadDeadline, controller.SetWriteDeadline} {
		if err := setDeadline(deadline); err != nil && !errors.Is(err, http.ErrNotSupported) {
			writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
			return
		}
	}
	if err := r.ParseMultipartForm(8 << 20); err != nil {
		var maxBytesErr *http.MaxBytesError
		if errors.As(err, &maxBytesErr) {
			writeError(w, apiError{Status: 413, Code: "download_too_large"})
		} else {
			writeError(w, apiError{Status: 400, Code: "invalid_request"})
		}
		return
	}
	defer r.MultipartForm.RemoveAll()
	platform := r.FormValue("platform")
	version := strings.TrimSpace(r.FormValue("version"))
	note := strings.TrimSpace(r.FormValue("note"))
	if platform != "macos" && platform != "ios" {
		writeError(w, apiError{Status: 400, Code: "invalid_request"})
		return
	}
	if utf8.RuneCountInString(version) < 1 || utf8.RuneCountInString(version) > 60 || utf8.RuneCountInString(note) > 500 {
		writeError(w, apiError{Status: 400, Code: "invalid_request"})
		return
	}
	file, header, err := r.FormFile("file")
	if err != nil {
		writeError(w, apiError{Status: 400, Code: "invalid_request"})
		return
	}
	defer file.Close()
	filename, ok := sanitizeDownloadName(header.Filename)
	if !ok {
		writeError(w, apiError{Status: 400, Code: "invalid_filename"})
		return
	}
	if header.Size > maxDownloadBytes {
		writeError(w, apiError{Status: 413, Code: "download_too_large"})
		return
	}
	if err := os.MkdirAll(a.cfg.DownloadDir, 0o755); err != nil {
		writeError(w, apiError{Status: 503, Code: "download_storage_unavailable"})
		return
	}
	temp, err := os.CreateTemp(a.cfg.DownloadDir, ".upload-*")
	if err != nil {
		writeError(w, apiError{Status: 503, Code: "download_storage_unavailable"})
		return
	}
	tempName := temp.Name()
	defer func() {
		temp.Close()
		_ = os.Remove(tempName)
	}()
	hasher := sha256.New()
	size, err := io.Copy(io.MultiWriter(temp, hasher), io.LimitReader(file, maxDownloadBytes+1))
	if err != nil {
		writeError(w, apiError{Status: 503, Code: "download_storage_unavailable"})
		return
	}
	if size < 4 || size > maxDownloadBytes {
		writeError(w, apiError{Status: 413, Code: "download_too_large"})
		return
	}
	headerBytes := make([]byte, 4)
	if _, err := temp.ReadAt(headerBytes, 0); err != nil || string(headerBytes[0:2]) != "PK" {
		writeError(w, apiError{Status: 400, Code: "invalid_file_type"})
		return
	}
	if err := temp.Sync(); err != nil {
		writeError(w, apiError{Status: 503, Code: "download_storage_unavailable"})
		return
	}
	if err := temp.Close(); err != nil {
		writeError(w, apiError{Status: 503, Code: "download_storage_unavailable"})
		return
	}
	finalPath := filepath.Join(a.cfg.DownloadDir, filename)
	s := currentSession(r)
	tx, err := a.db.Begin(r.Context())
	if err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	defer tx.Rollback(r.Context())
	var id string
	if err := tx.QueryRow(r.Context(), `INSERT INTO download_artifacts(platform,version,filename,size_bytes,sha256,note,created_by)
		VALUES($1,$2,$3,$4,$5,$6,$7) RETURNING id::text`,
		platform, version, filename, size, hex.EncodeToString(hasher.Sum(nil)), note, s.AdminID).Scan(&id); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	if err := a.auditTx(r.Context(), tx, s.AdminID, "admin.download.upload", "download_artifact", id, platform, "success", s.IPMac); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	// Link creates the final name without overwriting an existing archive, even
	// when two uploads with the same filename finish concurrently.
	if err := os.Link(tempName, finalPath); err != nil {
		if errors.Is(err, os.ErrExist) {
			writeError(w, apiError{Status: 409, Code: "download_filename_exists"})
		} else {
			writeError(w, apiError{Status: 503, Code: "download_storage_unavailable"})
		}
		return
	}
	// A commit error can have an uncertain outcome; retain the archive so an
	// already-committed database record never points at a removed file.
	if err := tx.Commit(r.Context()); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{"id": id, "filename": filename, "size_bytes": size,
		"sha256": hex.EncodeToString(hasher.Sum(nil)), "platform": platform, "version": version})
}

func (a *API) activateDownload(active bool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		id := strings.ToLower(r.PathValue("id"))
		if !isUUID(id) {
			writeError(w, apiError{Status: 400, Code: "invalid_request"})
			return
		}
		s := currentSession(r)
		tx, err := a.db.Begin(r.Context())
		if err != nil {
			writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
			return
		}
		defer tx.Rollback(r.Context())
		if active {
			var platform, filename string
			var size int64
			if err := tx.QueryRow(r.Context(), `SELECT platform,filename,size_bytes FROM download_artifacts WHERE id=$1 FOR UPDATE`, id).Scan(&platform, &filename, &size); err != nil {
				if errors.Is(err, pgx.ErrNoRows) {
					writeError(w, apiError{Status: 404, Code: "download_not_found"})
				} else {
					writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
				}
				return
			}
			root, openErr := os.OpenRoot(a.cfg.DownloadDir)
			if openErr != nil {
				writeError(w, apiError{Status: 409, Code: "download_file_unavailable"})
				return
			}
			file, openErr := root.Open(filename)
			root.Close()
			if openErr != nil {
				writeError(w, apiError{Status: 409, Code: "download_file_unavailable"})
				return
			}
			info, statErr := file.Stat()
			file.Close()
			if statErr != nil || !info.Mode().IsRegular() || info.Size() != size {
				writeError(w, apiError{Status: 409, Code: "download_file_unavailable"})
				return
			}
			if _, err := tx.Exec(r.Context(), `UPDATE download_artifacts SET is_active=false,activated_at=NULL WHERE platform=$1 AND is_active`, platform); err != nil {
				writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
				return
			}
		}
		tag, err := tx.Exec(r.Context(), `UPDATE download_artifacts SET is_active=$2,activated_at=CASE WHEN $2 THEN now() ELSE NULL END WHERE id=$1`, id, active)
		if err != nil {
			writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
			return
		}
		if tag.RowsAffected() == 0 {
			writeError(w, apiError{Status: 404, Code: "download_not_found"})
			return
		}
		action := "admin.download.deactivate"
		if active {
			action = "admin.download.activate"
		}
		if err := a.auditTx(r.Context(), tx, s.AdminID, action, "download_artifact", id, "", "success", s.IPMac); err != nil {
			writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
			return
		}
		if err := tx.Commit(r.Context()); err != nil {
			writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"id": id, "is_active": active})
	}
}

func (a *API) updateDownloadNote(w http.ResponseWriter, r *http.Request) {
	id := strings.ToLower(r.PathValue("id"))
	if !isUUID(id) {
		writeError(w, apiError{Status: 400, Code: "invalid_request"})
		return
	}
	var input struct {
		Note string `json:"note"`
	}
	if err := decodeJSON(w, r, &input); err != nil {
		writeError(w, err)
		return
	}
	if len([]rune(strings.TrimSpace(input.Note))) > 500 {
		writeError(w, apiError{Status: 400, Code: "invalid_request"})
		return
	}
	s := currentSession(r)
	tx, err := a.db.Begin(r.Context())
	if err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	defer tx.Rollback(r.Context())
	tag, err := tx.Exec(r.Context(), `UPDATE download_artifacts SET note=$2 WHERE id=$1`, id, strings.TrimSpace(input.Note))
	if err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	if tag.RowsAffected() == 0 {
		writeError(w, apiError{Status: 404, Code: "download_not_found"})
		return
	}
	if err := a.auditTx(r.Context(), tx, s.AdminID, "admin.download.note", "download_artifact", id, "", "success", s.IPMac); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	if err := tx.Commit(r.Context()); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"id": id, "note": strings.TrimSpace(input.Note)})
}
