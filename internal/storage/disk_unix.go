//go:build linux || darwin
// +build linux darwin

package storage

import (
	"fmt"
	"syscall"
)

// getDiskUsageOS returns disk usage for Linux/Darwin
func getDiskUsageOS(path string) (*DiskUsage, error) {
	var stat syscall.Statfs_t
	err := syscall.Statfs(path, &stat)
	if err != nil {
		return nil, fmt.Errorf("failed to get disk stats: %w", err)
	}

	total := stat.Blocks * uint64(stat.Bsize)
	free := stat.Bfree * uint64(stat.Bsize)
	used := total - free

	percentage := 0.0
	if total > 0 {
		percentage = float64(used) / float64(total) * 100
	}

	return &DiskUsage{
		Total:      total,
		Used:       used,
		Free:       free,
		Percentage: percentage,
	}, nil
}
