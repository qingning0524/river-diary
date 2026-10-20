package adminui

import (
	"embed"
	"io/fs"
	"net/http"
)

//go:embed all:generated
var assets embed.FS

func Handler() (http.Handler, error) {
	content, err := fs.Sub(assets, "generated")
	if err != nil {
		return nil, err
	}
	return http.FileServer(http.FS(content)), nil
}
