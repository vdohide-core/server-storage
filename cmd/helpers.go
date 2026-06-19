package main

import (
	"context"
	"fmt"
	"log"
	"time"

	"server-storage/internal/db/models"
	"server-storage/internal/utils"

	"github.com/google/uuid"
	"go.mongodb.org/mongo-driver/bson"
)

func newUUID() string { return uuid.NewString() }

func derefStr(s *string) string {
	if s == nil {
		return ""
	}
	return *s
}

func failProcess(ctx context.Context, processID, slug, errMsg string) {
	log.Printf("❌ [%s] ERROR: %s", slug, errMsg)

	retryNum := 1
	current, _ := models.VideoProcessModel.FindByID(ctx, processID)
	if current != nil && current.RetryCount != nil {
		retryNum = *current.RetryCount + 1
	}

	_, err := models.VideoProcessModel.Col().UpdateOne(ctx,
		bson.M{"_id": processID},
		bson.M{"$set": bson.M{
			"status":     models.ProcessStatusFailed,
			"error":      errMsg,
			"retryCount": retryNum,
			"updatedAt":  time.Now(),
		}},
	)
	if err != nil {
		log.Printf("❌ [%s] Process update failed: %v", slug, err)
		return
	}
	log.Printf("❌ [%s] Failed (retry %d/3): %s", slug, retryNum, errMsg)
}

func startStep(ctx context.Context, processID, step string) {
	now := time.Now()
	models.VideoProcessModel.UpdateByID(ctx, processID, bson.M{"$set": bson.M{
		fmt.Sprintf("timeline.%s.status", step):    models.StepStatusProcessing,
		fmt.Sprintf("timeline.%s.percent", step):   0,
		fmt.Sprintf("timeline.%s.startedAt", step): now,
		"updatedAt": now,
	}})
}

func completeStep(ctx context.Context, processID, step string) {
	now := time.Now()
	models.VideoProcessModel.UpdateByID(ctx, processID, bson.M{"$set": bson.M{
		fmt.Sprintf("timeline.%s.status", step):  models.StepStatusCompleted,
		fmt.Sprintf("timeline.%s.percent", step): 100,
		fmt.Sprintf("timeline.%s.endedAt", step): now,
		"updatedAt": now,
	}})
}

func updateTimelineStep(ctx context.Context, processID, step string, percent float64) {
	models.VideoProcessModel.UpdateByID(ctx, processID, bson.M{"$set": bson.M{
		fmt.Sprintf("timeline.%s.status", step):  models.StepStatusProcessing,
		fmt.Sprintf("timeline.%s.percent", step): percent,
		"updatedAt": time.Now(),
	}})
}

func updateOverallPercent(ctx context.Context, processID string, percent float64) {
	models.VideoProcessModel.UpdateByID(ctx, processID, bson.M{"$set": bson.M{
		"overallPercent": percent,
		"updatedAt":      time.Now(),
	}})
}

func cloneMediaToClonedFiles(ctx context.Context, sourceFileID string, media models.Media, slug string) {
	cursor, err := models.FileModel.FindRaw(ctx, bson.M{
		"clonedFrom":         sourceFileID,
		"type":               models.FileTypeVideo,
		"metadata.trashedAt": bson.M{"$exists": false},
		"metadata.deletedAt": bson.M{"$exists": false},
	})
	if err != nil {
		return
	}
	defer cursor.Close(ctx)

	for cursor.Next(ctx) {
		var clonedFile models.File
		if err := cursor.Decode(&clonedFile); err != nil {
			continue
		}

		count, _ := models.MediaModel.CountDocuments(ctx, bson.M{
			"fileId": clonedFile.ID,
			"type":   models.MediaTypeThumbnail,
		})
		if count > 0 {
			continue
		}

		now := time.Now()
		clonedMedia := models.Media{
			ID:        uuid.NewString(),
			Type:      media.Type,
			FileName:  media.FileName,
			StorageID: media.StorageID,
			Slug:      utils.RandomString(11, false),
			FileID:    &clonedFile.ID,
			Metadata:  media.Metadata,
			CreatedAt: now,
			UpdatedAt: now,
		}
		clonedFrom := sourceFileID
		clonedMedia.ClonedFrom = &clonedFrom

		if _, err := models.MediaModel.Create(ctx, &clonedMedia); err != nil {
			log.Printf("⚠️  [%s] Failed to clone sprite media to %s: %v", slug, clonedFile.ID, err)
			continue
		}
		log.Printf("📋 [%s] Cloned sprite media → file %s", slug, clonedFile.ID)
	}
}
