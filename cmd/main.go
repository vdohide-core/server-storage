package main

import (
	"context"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"server-storage/internal/config"
	"server-storage/internal/db/database"
	"server-storage/internal/handlers"
	"server-storage/internal/storage"
	"syscall"
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

	// Create cancellable context listening to OS signals for graceful shutdown
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	// Update disk usage on startup
	if err := updateDiskUsage(ctx); err != nil {
		log.Println("⚠️ Failed to update disk usage:", err)
	}

	// Periodic disk usage update (every 1 minute)
	go func() {
		ticker := time.NewTicker(1 * time.Minute)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				log.Println("🛑 Stopping disk usage update worker")
				return
			case <-ticker.C:
				if err := updateDiskUsage(ctx); err != nil {
					log.Println("⚠️ Failed to update disk usage:", err)
				}
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
		for {
			select {
			case <-ctx.Done():
				log.Println("🛑 Stopping deleted media cleanup worker")
				return
			case <-ticker.C:
				count, err := h.CleanupDeletedMedia(ctx)
				if err != nil {
					log.Printf("⚠️ Cleanup error: %v", err)
				} else if count > 0 {
					log.Printf("🗑️ Cleaned up %d deleted media files", count)
				}
			}
		}
	}()

	// Routes
	http.HandleFunc("/api/health", h.Health)
	http.HandleFunc("/", h.Home)

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

	server := &http.Server{
		Addr:    ":" + port,
		Handler: corsHandler,
	}

	// Start server in a goroutine
	go func() {
		fmt.Printf("Server started at http://localhost:%s\n", port)
		if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("Error starting server: %v", err)
		}
	}()

	// Wait for termination signal
	<-ctx.Done()
	log.Println("🔄 Shutting down server gracefully...")

	// Create a timeout context for the shutdown (5 seconds)
	shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer shutdownCancel()

	if err := server.Shutdown(shutdownCtx); err != nil {
		log.Printf("⚠️ Server shutdown failed: %v", err)
	} else {
		log.Println("✅ Server gracefully stopped")
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
