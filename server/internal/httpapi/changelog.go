package httpapi

import (
	"net/http"
	"time"
)

// Public changelog: published entries, newest first. Powers the website
// timeline and client "what's new" surfaces.

func (a *API) changelogPublished(w http.ResponseWriter, r *http.Request) {
	rows, err := a.db.Query(r.Context(), `SELECT id::text,to_char(entry_date,'YYYY-MM-DD'),version_tag,title,body,published_at
		FROM changelog_entries WHERE is_published AND published_at IS NOT NULL
		ORDER BY entry_date DESC, created_at DESC LIMIT 100`)
	if err != nil {
		a.databaseFailure(w, r, "changelog_public")
		return
	}
	defer rows.Close()
	type item struct {
		ID          string     `json:"id"`
		Date        string     `json:"date"`
		VersionTag  string     `json:"version_tag,omitempty"`
		Title       string     `json:"title"`
		Body        string     `json:"body,omitempty"`
		PublishedAt *time.Time `json:"published_at,omitempty"`
	}
	items := make([]item, 0)
	for rows.Next() {
		var it item
		if err := rows.Scan(&it.ID, &it.Date, &it.VersionTag, &it.Title, &it.Body, &it.PublishedAt); err != nil {
			rows.Close()
			a.databaseFailure(w, r, "changelog_public_scan")
			return
		}
		items = append(items, it)
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		a.databaseFailure(w, r, "changelog_public_err")
		return
	}
	rows.Close()
	w.Header().Set("Cache-Control", "public, max-age=30")
	writeJSON(w, http.StatusOK, map[string]any{"entries": items, "updated_at": time.Now().UTC()})
}
