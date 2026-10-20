package adminapi

import (
	"net/http"
	"regexp"
	"strings"
	"time"
)

// ---- 更新日志管理 ----

var changelogDatePattern = regexp.MustCompile(`^\d{4}-\d{2}-\d{2}$`)
var changelogVersionPattern = regexp.MustCompile(`^[A-Za-z0-9. _+-]{0,40}$`)

type changelogPayload struct {
	Date        string `json:"date"`
	VersionTag  string `json:"version_tag"`
	Title       string `json:"title"`
	Body        string `json:"body"`
	IsPublished bool   `json:"is_published"`
}

func (p *changelogPayload) validate() (time.Time, bool) {
	p.Title = strings.TrimSpace(p.Title)
	p.Body = strings.TrimSpace(p.Body)
	p.VersionTag = strings.TrimSpace(p.VersionTag)
	p.Date = strings.TrimSpace(p.Date)
	if len(p.Title) < 1 || len([]rune(p.Title)) > 160 || len([]rune(p.Body)) > 4000 || !changelogVersionPattern.MatchString(p.VersionTag) {
		return time.Time{}, false
	}
	if !changelogDatePattern.MatchString(p.Date) {
		return time.Time{}, false
	}
	parsed, err := time.Parse("2006-01-02", p.Date)
	if err != nil || parsed.Year() < 2020 || parsed.After(time.Now().AddDate(1, 0, 0)) {
		return time.Time{}, false
	}
	return parsed, true
}

func (a *API) listChangelog(w http.ResponseWriter, r *http.Request) {
	rows, err := a.db.Query(r.Context(), `SELECT c.id::text,to_char(c.entry_date,'YYYY-MM-DD'),c.version_tag,c.title,c.body,c.is_published,c.created_at,c.updated_at,c.published_at,COALESCE(u.username,'')
		FROM changelog_entries c LEFT JOIN admin_accounts u ON u.id=c.created_by
		ORDER BY c.entry_date DESC,c.created_at DESC LIMIT 200`)
	if err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	defer rows.Close()
	type item struct {
		ID          string     `json:"id"`
		Date        string     `json:"date"`
		VersionTag  string     `json:"version_tag"`
		Title       string     `json:"title"`
		Body        string     `json:"body"`
		IsPublished bool       `json:"is_published"`
		CreatedAt   time.Time  `json:"created_at"`
		UpdatedAt   time.Time  `json:"updated_at"`
		PublishedAt *time.Time `json:"published_at"`
		CreatedBy   string     `json:"created_by"`
	}
	items := make([]item, 0)
	for rows.Next() {
		var it item
		if err := rows.Scan(&it.ID, &it.Date, &it.VersionTag, &it.Title, &it.Body, &it.IsPublished, &it.CreatedAt, &it.UpdatedAt, &it.PublishedAt, &it.CreatedBy); err != nil {
			writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
			return
		}
		items = append(items, it)
	}
	if err := rows.Err(); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"entries": items})
}

func (a *API) createChangelog(w http.ResponseWriter, r *http.Request) {
	var input changelogPayload
	if err := decodeJSON(w, r, &input); err != nil {
		writeError(w, err)
		return
	}
	date, ok := input.validate()
	if !ok {
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
	if err := tx.QueryRow(r.Context(), `INSERT INTO changelog_entries(entry_date,version_tag,title,body,is_published,published_at,created_by)
		VALUES($1,$2,$3,$4,$5,CASE WHEN $5 THEN now() ELSE NULL END,$6) RETURNING id::text`,
		date, input.VersionTag, input.Title, input.Body, input.IsPublished, s.AdminID).Scan(&id); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	if err := a.auditTx(r.Context(), tx, s.AdminID, "admin.changelog.create", "changelog_entry", id, input.Date, "success", s.IPMac); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	if err := tx.Commit(r.Context()); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{"id": id, "status": "created"})
}

func (a *API) updateChangelog(w http.ResponseWriter, r *http.Request) {
	id := strings.ToLower(r.PathValue("id"))
	if !isUUID(id) {
		writeError(w, apiError{Status: 400, Code: "invalid_request"})
		return
	}
	var input changelogPayload
	if err := decodeJSON(w, r, &input); err != nil {
		writeError(w, err)
		return
	}
	date, ok := input.validate()
	if !ok {
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
	tag, err := tx.Exec(r.Context(), `UPDATE changelog_entries SET entry_date=$2,version_tag=$3,title=$4,body=$5,is_published=$6,
		published_at=CASE WHEN $6 THEN COALESCE(published_at,now()) ELSE NULL END,updated_at=now() WHERE id=$1`,
		id, date, input.VersionTag, input.Title, input.Body, input.IsPublished)
	if err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	if tag.RowsAffected() == 0 {
		writeError(w, apiError{Status: 404, Code: "changelog_not_found"})
		return
	}
	if err := a.auditTx(r.Context(), tx, s.AdminID, "admin.changelog.update", "changelog_entry", id, input.Date, "success", s.IPMac); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	if err := tx.Commit(r.Context()); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"id": id, "status": "updated"})
}

func (a *API) deleteChangelog(w http.ResponseWriter, r *http.Request) {
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
	tag, err := tx.Exec(r.Context(), `DELETE FROM changelog_entries WHERE id=$1`, id)
	if err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	if tag.RowsAffected() == 0 {
		writeError(w, apiError{Status: 404, Code: "changelog_not_found"})
		return
	}
	if err := a.auditTx(r.Context(), tx, s.AdminID, "admin.changelog.delete", "changelog_entry", id, "", "success", s.IPMac); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	if err := tx.Commit(r.Context()); err != nil {
		writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"id": id, "status": "deleted"})
}

func (a *API) activateChangelog(published bool) http.HandlerFunc {
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
		tag, err := tx.Exec(r.Context(), `UPDATE changelog_entries SET is_published=$2,updated_at=now(),
			published_at=CASE WHEN $2 THEN COALESCE(published_at,now()) ELSE NULL END WHERE id=$1`, id, published)
		if err != nil {
			writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
			return
		}
		if tag.RowsAffected() == 0 {
			writeError(w, apiError{Status: 404, Code: "changelog_not_found"})
			return
		}
		action := "admin.changelog.unpublish"
		if published {
			action = "admin.changelog.publish"
		}
		if err := a.auditTx(r.Context(), tx, s.AdminID, action, "changelog_entry", id, "", "success", s.IPMac); err != nil {
			writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
			return
		}
		if err := tx.Commit(r.Context()); err != nil {
			writeError(w, apiError{Status: 503, Code: "temporarily_unavailable"})
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"id": id, "is_published": published})
	}
}
