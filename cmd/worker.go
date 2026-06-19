package main

import (
	"context"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"
	"time"

	"server-storage/internal/config"
	"server-storage/internal/db/models"
	"server-storage/internal/sprite"
	"server-storage/internal/utils"

	"go.mongodb.org/mongo-driver/bson"
	"go.mongodb.org/mongo-driver/mongo"
	"go.mongodb.org/mongo-driver/mongo/options"
)

var spriteWorkerID string

func startSpriteWorker(ctx context.Context) {
	spriteWorkerID = utils.GenerateWorkerID()
	log.Printf("⚡ Sprite worker started [Worker: %s]", spriteWorkerID)

	const (
		pollBusy = 5 * time.Second
		pollIdle = 30 * time.Second
	)

	for {
		select {
		case <-ctx.Done():
			log.Println("🛑 Stopping sprite worker")
			return
		default:
		}

		if !isSpriteEnabled(ctx) {
			time.Sleep(pollIdle)
			continue
		}

		hadWork := processNextSpriteJob(ctx)
		if hadWork {
			time.Sleep(pollBusy)
		} else {
			time.Sleep(pollIdle)
		}
	}
}

func isSpriteEnabled(ctx context.Context) bool {
	setting, err := models.SettingModel.FindOne(ctx, bson.M{"name": models.SettingSpriteEnabled})
	if err != nil {
		if err == mongo.ErrNoDocuments {
			newSetting := models.SettingModel.New()
			newSetting.Name = models.SettingSpriteEnabled
			newSetting.Value = true
			models.SettingModel.Create(ctx, newSetting)
			log.Println("⚙️  Created 'sprite_enabled' = true")
			return true
		}
		return true
	}
	return setting.GetBool(true)
}

func processNextSpriteJob(ctx context.Context) bool {
	cleanupMaxRetrySpriteProcesses(ctx)

	if process := resumeOwnSpriteProcess(ctx); process != nil {
		slug := derefStr(process.Slug)
		if err := runSprite(ctx, process); err != nil {
			log.Printf("❌ Sprite resume failed: %s - %v", slug, err)
		}
		return true
	}

	process, file, err := findAndClaimSpriteFile(ctx)
	if err == nil && process != nil {
		slug := derefStr(process.Slug)
		log.Printf("🖼️  New sprite job: [%s] %s", slug, file.Name)
		if err := runSprite(ctx, process); err != nil {
			log.Printf("❌ Sprite failed: %s - %v", slug, err)
		}
		return true
	}

	return false
}

func resumeOwnSpriteProcess(ctx context.Context) *models.VideoProcess {
	process, err := models.VideoProcessModel.FindOne(ctx, bson.M{
		"workerId":    spriteWorkerID,
		"status":      models.ProcessStatusProcessing,
		"processType": models.ProcessTypeSprite,
	})
	if err == nil {
		log.Printf("🔄 [%s] Resuming interrupted sprite process", derefStr(process.Slug))
		return process
	}

	failed, err := models.VideoProcessModel.FindOne(ctx, bson.M{
		"workerId":    spriteWorkerID,
		"status":      models.ProcessStatusFailed,
		"processType": models.ProcessTypeSprite,
		"retryCount":  bson.M{"$lt": 3},
	})
	if err == nil {
		slug := derefStr(failed.Slug)
		retryNum := 0
		if failed.RetryCount != nil {
			retryNum = *failed.RetryCount
		}
		waitSec := 30
		if retryNum >= 2 {
			waitSec = 60
		}
		log.Printf("🔁 [%s] Retrying sprite (attempt %d/3) — waiting %ds...", slug, retryNum+1, waitSec)
		time.Sleep(time.Duration(waitSec) * time.Second)

		models.VideoProcessModel.Col().UpdateOne(ctx,
			bson.M{"_id": failed.ID},
			bson.M{"$set": bson.M{
				"status":    models.ProcessStatusProcessing,
				"error":     "",
				"updatedAt": time.Now(),
			}},
		)
		status := models.ProcessStatusProcessing
		failed.Status = &status
		return failed
	}

	return nil
}

func cleanupMaxRetrySpriteProcesses(ctx context.Context) {
	processes, _ := models.VideoProcessModel.Find(ctx, bson.M{
		"workerId":    spriteWorkerID,
		"status":      models.ProcessStatusFailed,
		"processType": models.ProcessTypeSprite,
		"retryCount":  bson.M{"$gte": 3},
	})
	for _, pf := range processes {
		slug := derefStr(pf.Slug)
		log.Printf("🚫 [%s] Sprite permanently failed (3/3) — process kept as marker", slug)
		removeSpriteDownloadDir(slug)
	}
}

func findAndClaimSpriteFile(ctx context.Context) (*models.VideoProcess, *models.File, error) {
	storageID := config.AppConfig.StorageId

	filter := bson.M{
		"status":             models.FileStatusReady,
		"type":               models.FileTypeVideo,
		"clonedFrom":         bson.M{"$exists": false},
		"metadata.trashedAt": bson.M{"$exists": false},
		"metadata.deletedAt": bson.M{"$exists": false},
	}
	opts := options.Find().
		SetSort(bson.D{{Key: "createdAt", Value: 1}}).
		SetLimit(20)

	cursor, err := models.FileModel.FindRaw(ctx, filter, opts)
	if err != nil {
		return nil, nil, err
	}
	defer cursor.Close(ctx)

	for cursor.Next(ctx) {
		var file models.File
		if err := cursor.Decode(&file); err != nil {
			continue
		}

		// Must have video on this storage node
		videoCount, _ := models.MediaModel.CountDocuments(ctx, bson.M{
			"fileId":    file.ID,
			"type":      models.MediaTypeVideo,
			"storageId": storageID,
			"deletedAt": nil,
		})
		if videoCount == 0 {
			continue
		}

		// Skip if sprite already exists
		if hasSprite(ctx, file.ID) {
			continue
		}

		// Skip if any video_process exists for this file (unique index on fileId)
		anyProcess, _ := models.VideoProcessModel.CountDocuments(ctx, bson.M{
			"fileId": file.ID,
		})
		if anyProcess > 0 {
			continue
		}

		process, err := claimSpriteFile(ctx, &file)
		if err != nil {
			log.Printf("⚠️  [%s] Sprite claim failed: %v", file.Slug, err)
			continue
		}
		return process, &file, nil
	}

	return nil, nil, nil
}

func hasSprite(ctx context.Context, fileID string) bool {
	storageID := config.AppConfig.StorageId
	storagePath := config.AppConfig.StoragePath

	thumbCount, _ := models.MediaModel.CountDocuments(ctx, bson.M{
		"fileId":    fileID,
		"type":      models.MediaTypeThumbnail,
		"storageId": storageID,
		"deletedAt": nil,
	})
	if thumbCount > 0 {
		return true
	}

	vttPath := filepath.Join(storagePath, fileID, "sprite", sprite.VTTFileName)
	if _, err := os.Stat(vttPath); err == nil {
		return true
	}
	return false
}

func claimSpriteFile(ctx context.Context, file *models.File) (*models.VideoProcess, error) {
	now := time.Now()
	processing := models.ProcessStatusProcessing
	pending := models.StepStatusPending

	process := &models.VideoProcess{
		ID:          newUUID(),
		FileID:      &file.ID,
		Slug:        &file.Slug,
		WorkerID:    &spriteWorkerID,
		Status:      &processing,
		SpaceID:     file.SpaceID,
		ProcessType: models.ProcessTypeSprite,
		Timeline: bson.M{
			"fetch_vtt":    bson.M{"status": pending},
			"fetch_images": bson.M{"status": pending},
			"install":      bson.M{"status": pending},
		},
		CreatedAt: now,
		UpdatedAt: now,
	}

	if _, err := models.VideoProcessModel.Create(ctx, process); err != nil {
		return nil, err
	}
	log.Printf("🆕 [%s] Claimed for sprite (fileId=%s)", file.Slug, file.ID)
	return process, nil
}

func findSmallestVideoOnStorage(ctx context.Context, fileID, storageID string) (*models.Media, error) {
	resolutions := []string{
		models.Resolution360,
		models.Resolution480,
		models.Resolution720,
		models.Resolution1080,
		models.ResolutionOriginal,
	}

	for _, res := range resolutions {
		media, err := models.MediaModel.FindOne(ctx, bson.M{
			"fileId":     fileID,
			"type":       models.MediaTypeVideo,
			"resolution": res,
			"storageId":  storageID,
			"deletedAt":  nil,
		})
		if err == nil {
			return media, nil
		}
	}
	return nil, fmt.Errorf("no video media on storage %s for file %s", storageID, fileID)
}

func runSprite(ctx context.Context, process *models.VideoProcess) error {
	fileID := derefStr(process.FileID)
	slug := derefStr(process.Slug)
	storageID := config.AppConfig.StorageId
	storagePath := config.AppConfig.StoragePath
	vodURL := config.AppConfig.VodURL

	exePath, _ := os.Executable()
	baseDir := filepath.Dir(exePath)
	if strings.Contains(exePath, "go-build") {
		baseDir, _ = os.Getwd()
	}
	downloadDir := filepath.Join(baseDir, "download", slug)
	tempSpriteDir := filepath.Join(downloadDir, "sprite")

	var success bool
	defer func() {
		if success {
			os.RemoveAll(downloadDir)
			log.Printf("🧹 [%s] Cleaned up sprite temp dir", slug)
		} else {
			log.Printf("⚠️  [%s] Keeping sprite temp dir for retry: %s", slug, downloadDir)
		}
	}()

	log.Printf("🖼️  [%s] START SPRITE", slug)

	// Already done (race or resume after partial install)
	if hasSprite(ctx, fileID) {
		log.Printf("✅ [%s] Sprite already exists — removing process", slug)
		models.VideoProcessModel.DeleteByID(ctx, process.ID)
		success = true
		return nil
	}

	videoMedia, err := findSmallestVideoOnStorage(ctx, fileID, storageID)
	if err != nil {
		failProcess(ctx, process.ID, slug, err.Error())
		return err
	}

	log.Printf("📹 [%s] Using video media slug=%s res=%s", slug, videoMedia.Slug, derefStr(videoMedia.Resolution))

	// ─── STEP 1: FETCH VTT ───────────────────────────────────
	startStep(ctx, process.ID, "fetch_vtt")
	updateOverallPercent(ctx, process.ID, 5)

	vttBytes, err := sprite.Fetch(ctx, sprite.VTTURL(vodURL, videoMedia.Slug))
	if err != nil {
		failProcess(ctx, process.ID, slug, fmt.Sprintf("fetch vtt: %v", err))
		return err
	}
	completeStep(ctx, process.ID, "fetch_vtt")
	updateOverallPercent(ctx, process.ID, 10)

	imageNames := sprite.ParseImageNames(vttBytes)
	if len(imageNames) == 0 {
		failProcess(ctx, process.ID, slug, "no sprite images in vtt")
		return fmt.Errorf("no sprite images in vtt")
	}

	// ─── STEP 2: FETCH IMAGES ────────────────────────────────
	startStep(ctx, process.ID, "fetch_images")
	os.MkdirAll(tempSpriteDir, 0755)

	var totalSize int64
	for i, name := range imageNames {
		data, err := sprite.Fetch(ctx, sprite.ImageURL(vodURL, videoMedia.Slug, name))
		if err != nil {
			failProcess(ctx, process.ID, slug, fmt.Sprintf("fetch %s: %v", name, err))
			return err
		}
		if err := os.WriteFile(filepath.Join(tempSpriteDir, name), data, 0644); err != nil {
			failProcess(ctx, process.ID, slug, fmt.Sprintf("write %s: %v", name, err))
			return err
		}
		totalSize += int64(len(data))

		pct := float64(i+1) / float64(len(imageNames)) * 100
		updateTimelineStep(ctx, process.ID, "fetch_images", pct)
		updateOverallPercent(ctx, process.ID, 10+pct*0.75)
	}

	if err := os.WriteFile(filepath.Join(tempSpriteDir, sprite.VTTFileName), vttBytes, 0644); err != nil {
		failProcess(ctx, process.ID, slug, fmt.Sprintf("write vtt: %v", err))
		return err
	}
	totalSize += int64(len(vttBytes))

	completeStep(ctx, process.ID, "fetch_images")
	updateOverallPercent(ctx, process.ID, 85)
	log.Printf("✅ [%s] Downloaded %d sprite sheet(s)", slug, len(imageNames))

	// ─── STEP 3: INSTALL to /home/files/{fileId}/sprite ──────
	startStep(ctx, process.ID, "install")
	updateOverallPercent(ctx, process.ID, 90)

	if err := sprite.Install(tempSpriteDir, storagePath, fileID); err != nil {
		failProcess(ctx, process.ID, slug, fmt.Sprintf("install: %v", err))
		return err
	}
	completeStep(ctx, process.ID, "install")

	// ─── STEP 4: CREATE MEDIA RECORD ─────────────────────────
	fileName := sprite.VTTFileName
	storageIDPtr := storageID
	now := time.Now()

	media := models.Media{
		ID:        newUUID(),
		Type:      models.MediaTypeThumbnail,
		FileName:  &fileName,
		StorageID: &storageIDPtr,
		Slug:      utils.RandomString(11, false),
		FileID:    &fileID,
		Metadata: &models.MediaMetadata{
			Size: totalSize,
		},
		CreatedAt: now,
		UpdatedAt: now,
	}
	if _, err := models.MediaModel.Create(ctx, &media); err != nil {
		failProcess(ctx, process.ID, slug, fmt.Sprintf("create media: %v", err))
		return err
	}
	log.Printf("✅ [%s] Created sprite media record", slug)

	cloneMediaToClonedFiles(ctx, fileID, media, slug)

	updateOverallPercent(ctx, process.ID, 100)
	success = true

	models.VideoProcessModel.DeleteByID(ctx, process.ID)
	log.Printf("✅ [%s] Sprite complete (%d files, %.1f KB)", slug, len(imageNames)+1, float64(totalSize)/1024)
	return nil
}

func removeSpriteDownloadDir(slug string) {
	exePath, _ := os.Executable()
	baseDir := filepath.Dir(exePath)
	if strings.Contains(exePath, "go-build") {
		baseDir, _ = os.Getwd()
	}
	os.RemoveAll(filepath.Join(baseDir, "download", slug))
}
