//go:build linux

package adminapi

import (
	"bufio"
	"os"
	"strconv"
	"strings"
	"syscall"
)

type memorySnapshot struct {
	TotalBytes     uint64 `json:"total_bytes"`
	AvailableBytes uint64 `json:"available_bytes"`
}
type diskSnapshot struct {
	TotalBytes     uint64 `json:"total_bytes"`
	AvailableBytes uint64 `json:"available_bytes"`
}

func readSystemResources() map[string]any {
	memory := memorySnapshot{}
	file, err := os.Open("/proc/meminfo")
	if err == nil {
		scanner := bufio.NewScanner(file)
		for scanner.Scan() {
			parts := strings.Fields(scanner.Text())
			if len(parts) < 2 {
				continue
			}
			value, e := strconv.ParseUint(parts[1], 10, 64)
			if e != nil {
				continue
			}
			switch strings.TrimSuffix(parts[0], ":") {
			case "MemTotal":
				memory.TotalBytes = value * 1024
			case "MemAvailable":
				memory.AvailableBytes = value * 1024
			}
		}
		_ = file.Close()
	}
	disk := diskSnapshot{}
	var stat syscall.Statfs_t
	if err := syscall.Statfs("/", &stat); err == nil {
		unit := uint64(stat.Bsize)
		disk.TotalBytes = stat.Blocks * unit
		disk.AvailableBytes = stat.Bavail * unit
	}
	load := ""
	if raw, err := os.ReadFile("/proc/loadavg"); err == nil {
		fields := strings.Fields(string(raw))
		if len(fields) >= 3 {
			load = strings.Join(fields[:3], " ")
		}
	}
	return map[string]any{"memory": memory, "disk_root": disk, "load_average_1_5_15_minutes": load}
}
