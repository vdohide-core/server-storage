# Server Storage

Storage server สำหรับให้บริการไฟล์วิดีโอ (VOD) ผ่าน HTTP รองรับ nginx-vod-module manifest และจัดการ lifecycle ของไฟล์อัตโนมัติ สำหรับ [VDOHide](https://vdohide.com)

## Features

- 🎬 **Video Streaming** — เสิร์ฟไฟล์ `.mp4` พร้อม HTTP Range support (seeking)
- 📄 **VOD Manifest** — สร้าง JSON manifest สำหรับ nginx-vod-module
- 🗂️ **File Serving** — เสิร์ฟไฟล์ทั่วไปผ่าน slug lookup พร้อม cache headers
- 💾 **Disk Monitoring** — อัปเดต disk usage ไปที่ MongoDB ทุก 1 นาที
- 🗑️ **Auto Cleanup** — ลบไฟล์ที่ถูก soft-delete จาก disk อัตโนมัติทุก 1 นาที
- 🏥 **Health Check** — endpoint ตรวจสอบ status + disk info

## Requirements

- Go 1.24+
- MongoDB

---

## Installation (Linux Server)

### One-line install

```bash
curl -fsSL https://raw.githubusercontent.com/vdohide-core/server-storage/main/install.sh | sudo -E bash -s -- \
    --mongodb-uri "mongodb+srv://user:pass@host/dbname" \
    --storage-id "your-storage-uuid"
```

### Options

| Option | Default | คำอธิบาย |
|---|---|---|
| `-p, --port` | `8888` | HTTP port |
| `--mongodb-uri` | `""` | MongoDB connection string |
| `--storage-id` | `""` | **จำเป็น** — UUID ของ storage node ใน database |
| `--storage-path` | `/home/files` | path สำหรับเก็บไฟล์บน disk |
| `--uninstall` | — | ถอนการติดตั้ง |

### Examples

```bash
# Full install
curl -fsSL https://raw.githubusercontent.com/vdohide-core/server-storage/main/install.sh | sudo -E bash -s -- \
    --port 8888 \
    --mongodb-uri "mongodb+srv://user:pass@cluster.mongodb.net/platform" \
    --storage-id "6c4de678-a29c-44c9-bc2d-9c281936a012" \
    --storage-path "/home/files"

# Uninstall
curl -fsSL https://raw.githubusercontent.com/vdohide-core/server-storage/main/install.sh | sudo bash -s -- --uninstall
```

### After install

```bash
# ดู logs
journalctl -u server-storage -f

# Restart
systemctl restart server-storage

# Status
systemctl status server-storage
```

---

## Configuration (.env)

```env
MONGODB_URI=mongodb+srv://user:password@host/database_name
PORT=8888
STORAGE_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
STORAGE_PATH=/home/files
```

| Variable | Description | Default |
|---|---|---|
| `MONGODB_URI` | MongoDB connection string (รองรับ `MONGO_URI` ด้วย) | `mongodb://localhost:27017` |
| `PORT` | พอร์ตที่ server listen | `8888` |
| `STORAGE_ID` | **จำเป็น** — UUID ของ storage node ใน database | — |
| `STORAGE_PATH` | path สำหรับเก็บไฟล์บน disk | `./uploads` |

> **หมายเหตุ:** `STORAGE_ID` ต้องตรงกับ `_id` ของ document ใน collection `storages`

---

## API Endpoints

### `GET /{slug}.mp4`

เสิร์ฟไฟล์วิดีโอ พร้อม Range header support สำหรับ seeking

### `GET /{slug}.json`

สร้าง VOD JSON manifest สำหรับ nginx-vod-module:

```json
{
  "sequences": [
    {
      "clips": [
        { "type": "source", "path": "/home/files/abc123/video.mp4" }
      ]
    }
  ]
}
```

### `GET /{slug}/{file}`

เสิร์ฟไฟล์ทั่วไป (รูปภาพ, subtitle ฯลฯ) ผ่าน file slug lookup

### `GET /api/health`

Health check endpoint:

```json
{
  "status": "ok",
  "storageId": "6c4de678-a29c-44c9-bc2d-9c281936a012",
  "uptime": "2h15m30s",
  "disk": {
    "total": 107374182400,
    "used": 53687091200,
    "free": 53687091200,
    "percentage": 50.0
  }
}
```

---

## Background Tasks

| Task | Interval | Description |
|---|---|---|
| Disk Usage Update | 1 นาที | อัปเดต `capacity` + `heartbeatAt` + `status` ใน collection `storages` |
| Cleanup Deleted Media | 1 นาที | ลบไฟล์ที่มี `deletedAt` จาก disk แล้วลบ document ออกจาก collection `medias` (สูงสุด **100** รายการต่อรอบ) |

---

## File Structure

ไฟล์ถูกจัดเก็บในรูปแบบ:

```
{STORAGE_PATH}/
  └── {fileId}/
      ├── {file_name}          ← video (เช่น 1080.mp4)
      └── sprite/              ← thumbnail sprites
          ├── sprite.vtt
          ├── 1.jpg
          └── ...
```

เช่น: `/home/files/6c4de678-a29c-44c9-bc2d-9c281936a012/1080.mp4`

---

## Download Latest Release

```bash
# Linux amd64
curl -L https://github.com/vdohide-core/server-storage/releases/latest/download/server-storage-linux -o server-storage
chmod +x server-storage

# Linux ARM64
curl -L https://github.com/vdohide-core/server-storage/releases/latest/download/server-storage-linux-arm64 -o server-storage
chmod +x server-storage
```

---

## Development

```bash
# Clone
git clone https://github.com/vdohide-core/server-storage.git
cd server-storage

# สร้าง .env
cp .env .env.local

# Run
go run ./cmd

# Build all platforms
./build.bat
```

---

## Release

```bash
git tag v1.0.0
git push origin v1.0.0
```

GitHub Actions จะ build และ release อัตโนมัติพร้อม:
- `server-storage-linux` — Linux amd64 binary
- `server-storage-linux-arm64` — Linux ARM64 binary

---

## Database Schema

### Collection: `storages`

| Field | Type | Description |
|---|---|---|
| `_id` | String (UUID) | Storage ID |
| `name` | String | ชื่อ storage node |
| `enable` | Boolean | เปิด/ปิดการใช้งาน |
| `type` | String | `local` หรือ `s3` |
| `status` | String | `online`, `offline`, `error`, `maintenance` |
| `local` | Object | config สำหรับ local storage (host, port, path, ssh) |
| `s3` | Object | config สำหรับ S3-compatible storage |
| `publicUrl` | String | URL สำหรับเข้าถึงไฟล์จากภายนอก |
| `accepts` | Array | ประเภทไฟล์ที่รับ: `upload`, `video`, `image`, `other` |
| `capacity` | Object | `{ total, used, free, percentage }` |
| `heartbeatAt` | Date | เวลา heartbeat ล่าสุด |

### Collection: `medias`

| Field | Type | Description |
|---|---|---|
| `_id` | String (UUID) | Media ID |
| `type` | String | `video`, `audio`, `subtitle`, `thumbnail`, `image`, `document`, `other` |
| `file_name` | String | ชื่อไฟล์ |
| `mimeType` | String | MIME type |
| `resolution` | String | `1080`, `720`, `480`, `360`, `poster`, `gallery`, `trailer` |
| `storageId` | String | FK → `storages._id` |
| `slug` | String | unique slug สำหรับ URL |
| `fileId` | String | FK → `files._id` |
| `clonedFrom` | String | FK → `files._id` — ถ้า set = ใช้ไฟล์ร่วมกับ fileId นี้ |
| `metadata` | Object | `{ size, width, height, duration, directUrl }` |
| `deletedAt` | Date | เวลาที่ถูก soft-delete (null = ยังไม่ลบ) |

### Collection: `files`

| Field | Type | Description |
|---|---|---|
| `_id` | String (UUID) | File ID |
| `slug` | String | unique slug สำหรับ URL |
| `status` | String | `waiting`, `processing`, `ready`, `error` |
| `type` | String | `video`, `image`, `folder`, `space`, `other` |
| `name` | String | ชื่อไฟล์ |
| `clonedFrom` | String | FK → `files._id` — ถ้า set = ใช้ storage directory ของ source |
| `metadata.trashedAt` | Date | เวลาที่ถูกย้ายไป trash |
| `metadata.deletedAt` | Date | เวลาที่ถูก soft-delete |
