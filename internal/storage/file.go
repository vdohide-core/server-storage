package storage

import (
	"fmt"
	"log"
	"os"
	"path/filepath"
)

// DiskUsage contains disk usage information
type DiskUsage struct {
	Total      uint64
	Used       uint64
	Free       uint64
	Percentage float64
}

// GetDiskUsage returns disk usage for the given path
func GetDiskUsage(path string) (*DiskUsage, error) {
	// สร้างโฟลเดอร์ถ้ายังไม่มี
	os.MkdirAll(path, os.ModePerm)

	// แปลงเป็น absolute path (Windows API ต้องการ absolute path)
	absPath, err := filepath.Abs(path)
	if err != nil {
		return nil, fmt.Errorf("failed to resolve path: %w", err)
	}

	return getDiskUsageOS(absPath)
}

// DeleteFile deletes a file at the given path
func DeleteFile(filePath string) error {
	if _, err := os.Stat(filePath); os.IsNotExist(err) {
		log.Printf("⚠️ File not found (already deleted?): %s", filePath)
		return nil // File doesn't exist, consider it deleted
	}

	if err := os.Remove(filePath); err != nil {
		return fmt.Errorf("failed to delete file: %w", err)
	}

	log.Printf("🗑️ Deleted file: %s", filePath)
	return nil
}

// DeleteDir recursively removes a directory and all its contents.
// Useful for cleaning up directories with multiple files (e.g. HLS segments).
// Returns nil if the directory doesn't exist (already cleaned up).
func DeleteDir(dirPath string) error {
	if _, err := os.Stat(dirPath); os.IsNotExist(err) {
		return nil // Directory doesn't exist, nothing to do
	}

	if err := os.RemoveAll(dirPath); err != nil {
		return fmt.Errorf("failed to delete directory %s: %w", dirPath, err)
	}

	log.Printf("🗑️ Deleted directory: %s", dirPath)
	return nil
}

// IsDirEmpty checks if a directory is empty
func IsDirEmpty(dirPath string) (bool, error) {
	entries, err := os.ReadDir(dirPath)
	if err != nil {
		if os.IsNotExist(err) {
			return true, nil // Directory doesn't exist, consider it empty
		}
		return false, fmt.Errorf("failed to read directory: %w", err)
	}
	return len(entries) == 0, nil
}

// DeleteEmptyDir deletes a directory if it's empty
func DeleteEmptyDir(dirPath string) error {
	empty, err := IsDirEmpty(dirPath)
	if err != nil {
		return err
	}

	if !empty {
		return nil // Directory not empty, don't delete
	}

	if err := os.Remove(dirPath); err != nil {
		if os.IsNotExist(err) {
			return nil // Already deleted
		}
		return fmt.Errorf("failed to delete directory: %w", err)
	}

	log.Printf("🗑️ Deleted empty directory: %s", dirPath)
	return nil
}

// CleanupEmptyParentDirs walks up from the given path and deletes empty parent directories
// Stops at the basePath to avoid deleting too high in the tree
func CleanupEmptyParentDirs(filePath, basePath string) error {
	dirPath := filepath.Dir(filePath)

	// Keep going up until we hit the base path
	for dirPath != basePath && len(dirPath) > len(basePath) {
		empty, err := IsDirEmpty(dirPath)
		if err != nil {
			return err
		}

		if !empty {
			break // Stop if directory is not empty
		}

		if err := os.Remove(dirPath); err != nil {
			if os.IsNotExist(err) {
				dirPath = filepath.Dir(dirPath)
				continue
			}
			return fmt.Errorf("failed to delete directory %s: %w", dirPath, err)
		}

		log.Printf("🗑️ Deleted empty directory: %s", dirPath)
		dirPath = filepath.Dir(dirPath)
	}

	return nil
}
