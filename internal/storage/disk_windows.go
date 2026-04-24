//go:build windows
// +build windows

package storage

import (
	"fmt"
	"syscall"
	"unsafe"
)

// getDiskUsageOS returns disk usage for Windows
func getDiskUsageOS(path string) (*DiskUsage, error) {
	kernel32 := syscall.NewLazyDLL("kernel32.dll")
	getDiskFreeSpaceEx := kernel32.NewProc("GetDiskFreeSpaceExW")

	var freeBytesAvailable, totalBytes, totalFreeBytes uint64

	pathPtr, err := syscall.UTF16PtrFromString(path)
	if err != nil {
		return nil, fmt.Errorf("failed to convert path: %w", err)
	}

	ret, _, err := getDiskFreeSpaceEx.Call(
		uintptr(unsafe.Pointer(pathPtr)),
		uintptr(unsafe.Pointer(&freeBytesAvailable)),
		uintptr(unsafe.Pointer(&totalBytes)),
		uintptr(unsafe.Pointer(&totalFreeBytes)),
	)

	if ret == 0 {
		return nil, fmt.Errorf("GetDiskFreeSpaceExW failed: %w", err)
	}

	used := totalBytes - totalFreeBytes
	percentage := 0.0
	if totalBytes > 0 {
		percentage = float64(used) / float64(totalBytes) * 100
	}

	return &DiskUsage{
		Total:      totalBytes,
		Used:       used,
		Free:       totalFreeBytes,
		Percentage: percentage,
	}, nil
}
