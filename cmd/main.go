package main

import (
	"context"
	"fmt"
	"log"
	"net/http"
	"server-storage/internal/config"
	"server-storage/internal/db/database"
	"server-storage/internal/handlers"
	"server-storage/internal/storage"
	"time"

	"github.com/joho/godotenv"
	"go.mongodb.org/mongo-driver/bson"
)

var (
	storageID   string
	storagePath string
)

func main() {
	log.Println("🚀 Starting Storage Server")
	// Load .env (optional)
	_ = godotenv.Load()

	// Load config
	config.Load()

	// Connect to MongoDB
	if err := database.Connect(); err != nil {
		log.Fatal("Failed to connect to MongoDB:", err)
	}
	defer database.Disconnect()
	log.Println("✅ MongoDB connected")

	// Get port from environment or use default
	port := config.AppConfig.Port
	if port == "" {
		port = "8888"
	}

	// Get configuration from environment
	storagePath = config.AppConfig.StoragePath
	if storagePath == "" {
		storagePath = "./uploads" // Default path
	}

	storageID = config.AppConfig.StorageId
	if storageID == "" {
		log.Fatal("❌ STORAGE_ID environment variable is required")
	}

	log.Printf("📁 Storage Path: %s", storagePath)
	log.Printf("🆔 Storage ID: %s", storageID)

	// Update disk usage on startup
	ctx := context.Background()
	if err := updateDiskUsage(ctx); err != nil {
		log.Println("⚠️ Failed to update disk usage:", err)
	}

	// Periodic disk usage update (every 1 minute)
	go func() {
		ticker := time.NewTicker(1 * time.Minute)
		defer ticker.Stop()
		for range ticker.C {
			if err := updateDiskUsage(context.Background()); err != nil {
				log.Println("⚠️ Failed to update disk usage:", err)
			}
		}
	}()

	// Initialize handlers
	h := handlers.NewHandler(handlers.Handler{
		StoragePath: storagePath,
		StorageId:   storageID,
	})

	// Periodic cleanup of soft-deleted media (every 1 minute)
	go func() {
		ticker := time.NewTicker(1 * time.Minute)
		defer ticker.Stop()
		for range ticker.C {
			count, err := h.CleanupDeletedMedia(context.Background())
			if err != nil {
				log.Printf("⚠️ Cleanup error: %v", err)
			} else if count > 0 {
				log.Printf("🗑️ Cleaned up %d deleted media files", count)
			}
		}
	}()

	// Routes
	http.HandleFunc("/api/health", h.Health)
	http.HandleFunc("/", h.Home)

	fmt.Printf("Server started at http://localhost:%s\n", port)

	// CORS middleware
	corsHandler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "Content-Type, Authorization")
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusOK)
			return
		}
		http.DefaultServeMux.ServeHTTP(w, r)
	})

	if err := http.ListenAndServe(":"+port, corsHandler); err != nil {
		log.Println("Error starting server:", err)
	}
}

// updateDiskUsage updates the disk usage for this storage node
func updateDiskUsage(ctx context.Context) error {
	usage, err := storage.GetDiskUsage(storagePath)
	if err != nil {
		return err
	}

	log.Printf("💾 Disk usage: %.2f%% (Used: %.2f GB / Total: %.2f GB)",
		usage.Percentage,
		float64(usage.Used)/1024/1024/1024,
		float64(usage.Total)/1024/1024/1024,
	)

	// Update storage document in database
	filter := bson.M{"_id": storageID}
	update := bson.M{
		"$set": bson.M{
			"capacity": bson.M{
				"total":      int64(usage.Total),
				"used":       int64(usage.Used),
				"free":       int64(usage.Free),
				"percentage": usage.Percentage,
			},
			"heartbeatAt": time.Now(),
			"status":      "online",
		},
	}

	result, err := database.Storages().UpdateOne(ctx, filter, update)
	if err != nil {
		return err
	}

	if result.MatchedCount == 0 {
		log.Printf("⚠️ Storage node not found in database: %s", storageID)
	}

	return nil
}
