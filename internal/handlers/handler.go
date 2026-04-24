package handlers

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"server-storage/internal/db/database"
	"server-storage/internal/db/models"
	"strings"
	"time"

	"go.mongodb.org/mongo-driver/bson"
)

// Handler holds dependencies for HTTP handlers
type Handler struct {
	StoragePath string
	StorageId   string
}

// VOD Manifest structures (for nginx-vod-module)
type VODClip struct {
	Type string `json:"type"`
	Path string `json:"path"`
}

type VODSequence struct {
	Clips []VODClip `json:"clips"`
}

type VODManifest struct {
	Sequences []VODSequence `json:"sequences"`
}

// NewHandler creates a new Handler instance
func NewHandler(cfg Handler) *Handler {
	os.MkdirAll(cfg.StoragePath, os.ModePerm)
	return &cfg
}

func (h *Handler) Home(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path == "/" {
		HandleNotFound(w, r)
		return
	}

	// Extract slug from path
	path := strings.TrimPrefix(r.URL.Path, "/")

	// Parse path parts
	parts := strings.SplitN(path, "/", 2)

	switch {
	case len(parts) == 1 && strings.HasSuffix(path, ".mp4"):
		slug := strings.TrimSuffix(path, ".mp4")
		h.ServeVideo(w, r, slug)
	case len(parts) == 1 && strings.HasSuffix(path, ".json"):
		slug := strings.TrimSuffix(path, ".json")
		h.ServeVODManifest(w, r, slug)
	case len(parts) >= 2 && r.Method == http.MethodGet:
		// /{slug}/{file} or /{slug}/{folder}/{file}
		slug := parts[0]
		subPath := parts[1]
		h.ServeFile(w, r, slug, subPath)
	default:
		HandleNotFound(w, r)
	}
}

// findVideoMedia finds a video media record by slug
func (h *Handler) findVideoMedia(r *http.Request, slug string) (*models.Media, error) {
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()

	var media models.Media
	err := database.Medias().FindOne(ctx, bson.M{
		"type":       models.MediaTypeVideo,
		"slug":       slug,
		"storageId":  h.StorageId,
		"resolution": bson.M{"$in": []string{"original", "1080", "720", "480", "360"}},
	}).Decode(&media)
	if err != nil {
		return nil, err
	}

	if media.DeletedAt != nil {
		return nil, fmt.Errorf("media is deleted")
	}

	return &media, nil
}

// ServeVideo streams a video file with HTTP Range support for seeking
func (h *Handler) ServeVideo(w http.ResponseWriter, r *http.Request, slug string) {
	if slug == "" {
		HandleNotFound(w, r)
		return
	}

	media, err := h.findVideoMedia(r, slug)
	if err != nil {
		log.Printf("⚠️ Media not found: %s", slug)
		HandleNotFound(w, r)
		return
	}

	// Build file path: {storagePath}/{fileId}/{file_name}
	filePath := media.GetFilePath(h.StoragePath)

	// Check if file exists
	if _, err := os.Stat(filePath); os.IsNotExist(err) {
		log.Printf("⚠️ File not found on disk: %s", filePath)
		HandleNotFound(w, r)
		return
	}

	// http.ServeFile handles Range headers automatically for seeking
	w.Header().Set("Content-Type", "video/mp4")
	w.Header().Set("Accept-Ranges", "bytes")
	http.ServeFile(w, r, filePath)
}

// ServeVODManifest returns a VOD JSON manifest for nginx-vod-module
func (h *Handler) ServeVODManifest(w http.ResponseWriter, r *http.Request, slug string) {
	if slug == "" {
		HandleNotFound(w, r)
		return
	}

	media, err := h.findVideoMedia(r, slug)
	if err != nil {
		log.Printf("⚠️ Media not found: %s", slug)
		HandleNotFound(w, r)
		return
	}

	// Build file path: {storagePath}/{fileId}/{file_name}
	filePath := media.GetFilePath(h.StoragePath)

	// Build VOD manifest
	manifest := VODManifest{
		Sequences: []VODSequence{
			{
				Clips: []VODClip{
					{
						Type: "source",
						Path: filePath,
					},
				},
			},
		},
	}

	// Send JSON response
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Access-Control-Allow-Origin", "*")
	json.NewEncoder(w).Encode(manifest)
}
