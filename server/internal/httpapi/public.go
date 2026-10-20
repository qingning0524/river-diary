package httpapi

import (
	"errors"
	"mime"
	"net/http"
	"os"
	"regexp"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

// Public, unauthenticated read-only endpoints that power the marketing site
// and client apps. They only expose content published by administrators.

type publicAnnouncement struct {
	ID        string     `json:"id"`
	Level     string     `json:"level"`
	Title     string     `json:"title"`
	Body      string     `json:"body,omitempty"`
	Placement string     `json:"placement"`
	Href      string     `json:"href,omitempty"`
	StartsAt  *time.Time `json:"starts_at,omitempty"`
	EndsAt    *time.Time `json:"ends_at,omitempty"`
	UpdatedAt time.Time  `json:"updated_at"`
}

func (a *API) activeAnnouncements(r *http.Request) ([]publicAnnouncement, error) {
	rows, err := a.db.Query(r.Context(), `SELECT id::text,level,title,body,placement,href,starts_at,ends_at,updated_at
		FROM announcements
		WHERE active AND (starts_at IS NULL OR starts_at<=now()) AND (ends_at IS NULL OR ends_at>now())
		ORDER BY created_at DESC LIMIT 20`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	items := make([]publicAnnouncement, 0)
	for rows.Next() {
		var item publicAnnouncement
		if err := rows.Scan(&item.ID, &item.Level, &item.Title, &item.Body, &item.Placement, &item.Href, &item.StartsAt, &item.EndsAt, &item.UpdatedAt); err != nil {
			return nil, err
		}
		items = append(items, item)
	}
	return items, rows.Err()
}

func (a *API) announcementsActive(w http.ResponseWriter, r *http.Request) {
	items, err := a.activeAnnouncements(r)
	if err != nil {
		a.databaseFailure(w, r, "announcements_active")
		return
	}
	w.Header().Set("Cache-Control", "public, max-age=30")
	writeJSON(w, http.StatusOK, map[string]any{"announcements": items, "updated_at": time.Now().UTC()})
}

type publicDownload struct {
	Platform  string     `json:"platform"`
	Available bool       `json:"available"`
	Version   string     `json:"version,omitempty"`
	Filename  string     `json:"filename,omitempty"`
	SizeBytes int64      `json:"size_bytes,omitempty"`
	SHA256    string     `json:"sha256,omitempty"`
	Note      string     `json:"note,omitempty"`
	UpdatedAt *time.Time `json:"updated_at,omitempty"`
}

var publicDownloadFilenamePattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,180}\.zip$`)

// The account service reads its own private upload files. Publication is
// checked for every request, including HEAD, Range and conditional requests.
func (a *API) downloadArtifact(w http.ResponseWriter, r *http.Request) {
	filename := r.PathValue("filename")
	if !publicDownloadFilenamePattern.MatchString(filename) || strings.Contains(filename, "..") {
		writeError(w, r, apiError{Status: http.StatusNotFound, Code: "download_not_found"})
		return
	}
	var sha256 string
	err := a.db.QueryRow(r.Context(), `SELECT sha256 FROM download_artifacts WHERE is_active AND filename=$1 LIMIT 1`, filename).Scan(&sha256)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			writeError(w, r, apiError{Status: http.StatusNotFound, Code: "download_not_found"})
		} else {
			a.databaseFailure(w, r, "download_publication")
		}
		return
	}
	if a.cfg.DownloadDir == "" {
		writeError(w, r, apiError{Status: http.StatusServiceUnavailable, Code: "download_storage_unavailable"})
		return
	}
	root, err := os.OpenRoot(a.cfg.DownloadDir)
	if err != nil {
		writeError(w, r, apiError{Status: http.StatusServiceUnavailable, Code: "download_storage_unavailable"})
		return
	}
	defer root.Close()
	// Root.Open rejects symlinks escaping DOWNLOAD_DIR and remains confined
	// even if a path is replaced between validation and opening the archive.
	file, err := root.Open(filename)
	if err != nil {
		writeError(w, r, apiError{Status: http.StatusNotFound, Code: "download_not_found"})
		return
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil || !info.Mode().IsRegular() {
		writeError(w, r, apiError{Status: http.StatusNotFound, Code: "download_not_found"})
		return
	}
	// Only a published, safely opened archive gets the bounded transfer
	// window. Other account requests retain the server's short deadlines.
	controller := http.NewResponseController(w)
	deadline := time.Now().Add(10 * time.Minute)
	for _, setDeadline := range []func(time.Time) error{controller.SetReadDeadline, controller.SetWriteDeadline} {
		if err := setDeadline(deadline); err != nil && !errors.Is(err, http.ErrNotSupported) {
			writeError(w, r, apiError{Status: http.StatusServiceUnavailable, Code: "temporarily_unavailable"})
			return
		}
	}
	w.Header().Set("Content-Type", "application/zip")
	w.Header().Set("Content-Disposition", mime.FormatMediaType("attachment", map[string]string{"filename": filename}))
	w.Header().Set("ETag", `"`+sha256+`"`)
	http.ServeContent(w, r, filename, info.ModTime(), file)
}

func (a *API) siteStatus(w http.ResponseWriter, r *http.Request) {
	items, err := a.activeAnnouncements(r)
	if err != nil {
		a.databaseFailure(w, r, "site_status_announcements")
		return
	}
	downloads := map[string]publicDownload{"macos": {Platform: "macos"}, "ios": {Platform: "ios", Note: "正在准备 TestFlight 内测"}}
	rows, err := a.db.Query(r.Context(), `SELECT platform,version,filename,size_bytes,sha256,note,activated_at
		FROM download_artifacts WHERE is_active`)
	if err != nil {
		a.databaseFailure(w, r, "site_status_downloads")
		return
	}
	defer rows.Close()
	for rows.Next() {
		var item publicDownload
		var activated *time.Time
		if err := rows.Scan(&item.Platform, &item.Version, &item.Filename, &item.SizeBytes, &item.SHA256, &item.Note, &activated); err != nil {
			rows.Close()
			a.databaseFailure(w, r, "site_status_scan")
			return
		}
		item.Available = true
		item.UpdatedAt = activated
		downloads[item.Platform] = item
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		a.databaseFailure(w, r, "site_status_downloads_err")
		return
	}
	w.Header().Set("Cache-Control", "public, max-age=30")
	writeJSON(w, http.StatusOK, map[string]any{
		"announcements": items,
		"downloads":     downloads,
		"updated_at":    time.Now().UTC(),
	})
}
