package handlers

import (
	"encoding/json"
	"net/http"
	"server-storage/internal/storage"
	"time"
)

// HealthResponse represents the health check response
type HealthResponse struct {
	Status    string      `json:"status"`
	StorageId string      `json:"storageId"`
	Uptime    string      `json:"uptime"`
	Disk      *DiskHealth `json:"disk,omitempty"`
}

type DiskHealth struct {
	Total      int64   `json:"total"`
	Used       int64   `json:"used"`
	Free       int64   `json:"free"`
	Percentage float64 `json:"percentage"`
}

var startedAt = time.Now()

// Health returns the health status of this storage node
func (h *Handler) Health(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}

	resp := HealthResponse{
		Status:    "ok",
		StorageId: h.StorageId,
		Uptime:    time.Since(startedAt).Round(time.Second).String(),
	}

	// Get current disk usage
	usage, err := storage.GetDiskUsage(h.StoragePath)
	if err == nil {
		resp.Disk = &DiskHealth{
			Total:      int64(usage.Total),
			Used:       int64(usage.Used),
			Free:       int64(usage.Free),
			Percentage: usage.Percentage,
		}
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(resp)
}
