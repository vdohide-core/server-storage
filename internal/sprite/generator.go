package sprite

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
)

const VTTFileName = "sprite.vtt"

var httpClient = &http.Client{}

// Fetch downloads a URL and returns the response body.
func Fetch(ctx context.Context, url string) ([]byte, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}

	resp, err := httpClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		io.Copy(io.Discard, resp.Body)
		return nil, fmt.Errorf("unexpected status %d for %s", resp.StatusCode, url)
	}

	return io.ReadAll(resp.Body)
}

// ParseImageNames extracts unique JPEG filenames from a WebVTT body.
// Cue lines look like: sprite-1.jpg#xywh=0,0,160,90
func ParseImageNames(vtt []byte) []string {
	var names []string
	seen := make(map[string]struct{})

	for _, raw := range strings.Split(string(vtt), "\n") {
		line := strings.TrimSpace(raw)
		if !strings.Contains(line, ".jpg") {
			continue
		}
		if i := strings.IndexByte(line, '#'); i >= 0 {
			line = line[:i]
		}
		line = strings.TrimSpace(line)
		if !strings.HasSuffix(line, ".jpg") || strings.ContainsAny(line, "/\\ ") {
			continue
		}
		if _, ok := seen[line]; ok {
			continue
		}
		seen[line] = struct{}{}
		names = append(names, line)
	}

	return names
}

// VTTURL builds the nginx-vod sprite.vtt URL for a video media slug.
func VTTURL(vodBase, mediaSlug string) string {
	base := strings.TrimRight(vodBase, "/")
	return fmt.Sprintf("%s/sprite/%s.json/%s", base, mediaSlug, VTTFileName)
}

// ImageURL builds the nginx-vod sprite JPEG URL.
func ImageURL(vodBase, mediaSlug, imageName string) string {
	base := strings.TrimRight(vodBase, "/")
	return fmt.Sprintf("%s/sprite/%s.json/%s", base, mediaSlug, imageName)
}

// DownloadAll saves the vtt and every referenced JPEG into destDir.
// The vtt is written last so a partial folder is never usable.
func DownloadAll(ctx context.Context, vodBase, mediaSlug, destDir string, onImage func(done, total int)) (vtt []byte, totalSize int64, err error) {
	if err = os.MkdirAll(destDir, 0755); err != nil {
		return nil, 0, err
	}

	vtt, err = Fetch(ctx, VTTURL(vodBase, mediaSlug))
	if err != nil {
		return nil, 0, fmt.Errorf("fetch vtt: %w", err)
	}

	names := ParseImageNames(vtt)
	if len(names) == 0 {
		return nil, 0, fmt.Errorf("no sprite images in vtt")
	}

	for i, name := range names {
		data, err := Fetch(ctx, ImageURL(vodBase, mediaSlug, name))
		if err != nil {
			return nil, 0, fmt.Errorf("fetch %s: %w", name, err)
		}
		if err := os.WriteFile(filepath.Join(destDir, name), data, 0644); err != nil {
			return nil, 0, fmt.Errorf("write %s: %w", name, err)
		}
		totalSize += int64(len(data))
		if onImage != nil {
			onImage(i+1, len(names))
		}
	}

	if err := os.WriteFile(filepath.Join(destDir, VTTFileName), vtt, 0644); err != nil {
		return nil, 0, fmt.Errorf("write vtt: %w", err)
	}
	totalSize += int64(len(vtt))

	return vtt, totalSize, nil
}

// Install moves a completed temp sprite directory into permanent storage.
func Install(tempDir, storagePath, fileID string) error {
	destDir := filepath.Join(storagePath, fileID, "sprite")

	if _, err := os.Stat(destDir); err == nil {
		if err := os.RemoveAll(destDir); err != nil {
			return fmt.Errorf("remove old sprite dir: %w", err)
		}
	}

	if err := os.MkdirAll(filepath.Join(storagePath, fileID), 0755); err != nil {
		return fmt.Errorf("mkdir file dir: %w", err)
	}

	if err := os.Rename(tempDir, destDir); err != nil {
		return copyDir(tempDir, destDir)
	}
	return nil
}

func copyDir(src, dst string) error {
	if err := os.MkdirAll(dst, 0755); err != nil {
		return err
	}
	entries, err := os.ReadDir(src)
	if err != nil {
		return err
	}
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		data, err := os.ReadFile(filepath.Join(src, e.Name()))
		if err != nil {
			return err
		}
		if err := os.WriteFile(filepath.Join(dst, e.Name()), data, 0644); err != nil {
			return err
		}
	}
	return nil
}
