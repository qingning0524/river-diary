//go:build !linux

package adminapi

func readSystemResources() map[string]any { return map[string]any{"available": false} }
