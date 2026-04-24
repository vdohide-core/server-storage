package handlers

import (
	"context"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"server-storage/internal/db/database"
	"server-storage/internal/db/models"
	"strings"
	"time"

	"go.mongodb.org/mongo-driver/bson"
)

// ServeFile streams a file from disk based on File.Slug lookup.
// URL pattern: /{slug}/{file} or /{slug}/{folder}/{file}
// Disk path: {storagePath}/{file._id}/{subPath}
// If ClonedFrom is set: {storagePath}/{clonedFrom}/{subPath}
func (h *Handler) ServeFile(w http.ResponseWriter, r *http.Request, slug, subPath string) {
	// Reject if subPath is empty or has no file name (just a folder)
	if subPath == "" {
		HandleNotFound(w, r)
		return
	}

	// Must have a file name with extension — reject bare folder paths
	baseName := filepath.Base(subPath)
	if !strings.Contains(baseName, ".") {
		HandleNotFound(w, r)
		return
	}

	// Prevent path traversal
	if strings.Contains(subPath, "..") {
		HandleNotFound(w, r)
		return
	}

	// Lookup file by slug
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()

	var file models.File
	err := database.Files().FindOne(ctx, bson.M{
		"slug": slug,
	}).Decode(&file)
	if err != nil {
		log.Printf("⚠️ File not found by slug: %s", slug)
		HandleNotFound(w, r)
		return
	}

	// Reject trashed or deleted files
	if file.IsTrashed() || file.IsDeleted() {
		HandleNotFound(w, r)
		return
	}

	// Resolve disk directory: use ClonedFrom if set, otherwise _id
	dirID := file.ID
	if file.ClonedFrom != nil && *file.ClonedFrom != "" {
		dirID = *file.ClonedFrom
	}

	// Build full file path
	filePath := filepath.Join(h.StoragePath, dirID, subPath)

	// Check if file exists and is not a directory
	info, err := os.Stat(filePath)
	if err != nil || info.IsDir() {
		if err != nil {
			log.Printf("⚠️ File not found on disk: %s", filePath)
		}
		HandleNotFound(w, r)
		return
	}

	// Set cache headers — immutable, 1 year
	w.Header().Set("Cache-Control", "public, max-age=31536000, immutable")

	// http.ServeFile handles Content-Type detection and Range requests
	http.ServeFile(w, r, filePath)
}
