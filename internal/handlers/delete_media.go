package handlers

import (
	"context"
	"log"
	"server-storage/internal/db/database"
	"server-storage/internal/db/models"
	"server-storage/internal/storage"

	"go.mongodb.org/mongo-driver/bson"
	"go.mongodb.org/mongo-driver/mongo/options"
)

// CleanupDeletedMedia finds and deletes media files marked for deletion
func (h *Handler) CleanupDeletedMedia(ctx context.Context) (int, error) {
	filter := bson.M{
		"storageId": h.StorageId,
		"deletedAt": bson.M{"$ne": nil},
	}

	opts := options.Find().SetLimit(100)
	cursor, err := database.Medias().Find(ctx, filter, opts)
	if err != nil {
		return 0, err
	}
	defer cursor.Close(ctx)

	var deletedCount int

	for cursor.Next(ctx) {
		var media models.Media
		if err := cursor.Decode(&media); err != nil {
			log.Printf("⚠️ Failed to decode media: %v", err)
			continue
		}

		// Resolve the effective file ID (where the physical file lives)
		effectiveId := ""
		if media.FileID != nil {
			effectiveId = *media.FileID
		}
		if media.ClonedFrom != nil && *media.ClonedFrom != "" {
			effectiveId = *media.ClonedFrom
		}

		// Filter: other active media that resolves to the same effectiveId
		sameSourceFilter := bson.M{
			"_id":       bson.M{"$ne": media.ID},
			"deletedAt": nil,
			"$or": []bson.M{
				{"fileId": effectiveId, "clonedFrom": bson.M{"$in": []interface{}{nil, ""}}},
				{"clonedFrom": effectiveId},
			},
		}

		// Check if THIS specific file is used by anyone else
		if media.Type == models.MediaTypeThumbnail {
			// Thumbnail → check if other active thumbnail uses the same source
			sameSourceFilter["type"] = models.MediaTypeThumbnail
			count, err := database.Medias().CountDocuments(ctx, sameSourceFilter)
			if err != nil {
				log.Printf("⚠️ Failed to count refs for %s: %v", media.ID, err)
			} else if count == 0 {
				spriteDir := h.StoragePath + "/" + effectiveId + "/sprite"
				if err := storage.DeleteDir(spriteDir); err != nil {
					log.Printf("⚠️ Failed to delete sprite dir %s: %v", spriteDir, err)
				}
				storage.CleanupEmptyParentDirs(spriteDir+"/dummy", h.StoragePath)
			} else {
				log.Printf("⏭️ Skip sprite deletion for %s — %d other media still use it", media.ID, count)
			}
		} else {
			// Video/audio/etc. → check if other active media uses the same file
			fileName := ""
			if media.FileName != nil {
				fileName = *media.FileName
			}
			sameSourceFilter["file_name"] = fileName
			count, err := database.Medias().CountDocuments(ctx, sameSourceFilter)
			if err != nil {
				log.Printf("⚠️ Failed to count refs for %s: %v", media.ID, err)
			} else if count == 0 {
				filePath := h.StoragePath + "/" + effectiveId + "/" + fileName
				if err := storage.DeleteFile(filePath); err != nil {
					log.Printf("⚠️ Failed to delete file %s: %v", filePath, err)
				}
				storage.CleanupEmptyParentDirs(filePath, h.StoragePath)
			} else {
				log.Printf("⏭️ Skip file deletion for %s — %d other media still use %s", media.ID, count, fileName)
			}
		}

		// Always delete the media document from database
		if _, err := database.Medias().DeleteOne(ctx, bson.M{"_id": media.ID}); err != nil {
			log.Printf("⚠️ Failed to delete media document %s: %v", media.ID, err)
			continue
		}

		log.Printf("✅ Cleaned up media: %s (%s)", media.ID, func() string {
			if media.FileName != nil {
				return *media.FileName
			}
			return ""
		}())
		deletedCount++
	}

	if err := cursor.Err(); err != nil {
		return deletedCount, err
	}

	return deletedCount, nil
}
