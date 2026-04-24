# nginx-vod

ติดตั้ง [Kaltura nginx-vod-module](https://github.com/kaltura/nginx-vod-module) บน Ubuntu 24.04 พร้อม HLS/DASH streaming, thumbnail, URL rewrite และ anti-download protection

## สิ่งที่ได้หลังติดตั้ง

| Port | หน้าที่ |
|------|---------|
| `80` | Public proxy — URL สวย, ซ่อน segment เป็น `.jpeg` |
| `8889` | VOD server (mapped mode) — ใช้ภายใน |
| `8888` | JSON mapping server (upstream) |

### Features

- **HLS / DASH Streaming** — Adaptive bitrate streaming จากไฟล์ MP4 ในเครื่อง
- **Thumbnail Capture** — จับภาพ thumbnail ตามเวลาที่ต้องการ
- **Anti-Download** — Segment disguise เป็น `.jpeg` + rate limit 3MB/s
- **Friendly URL** — `/test/playlist.m3u8` แทน `/hls/test.json/master.m3u8`
- **CORS Ready** — รองรับ cross-origin requests ทุก endpoint
- **Large File Support** — รองรับไฟล์วิดีโอ 12-20GB (12+ ชม.)

---

## ความต้องการ

- Ubuntu 24.04 LTS
- Root access (`sudo`)
- Port 80, 8888, 8889 ว่าง

---

## การติดตั้ง

```bash
curl -fsSL https://raw.githubusercontent.com/vdohide-core/server-storage/main/nginx/vod/install.sh | sudo -E bash
```

#### ตั้งค่าเอง (Environment Variables)

| ตัวแปร | ค่าเริ่มต้น | คำอธิบาย |
|--------|-------------|----------|
| `SERVER_PORT` | `8889` | Port สำหรับ VOD server |
| `SEGMENT_DUR` | `4` | ความยาว segment (วินาที) |
| `MEDIA_ROOT` | `/home/files` | โฟลเดอร์เก็บไฟล์วิดีโอ |

**ตัวอย่าง** — เปลี่ยน port และ segment duration:

```bash
curl -fsSL https://raw.githubusercontent.com/vdohide-core/server-storage/main/nginx/vod/install.sh \
  | sudo -E SERVER_PORT=9000 SEGMENT_DUR=6 bash
```

#### สิ่งที่ script ทำ

1. ติดตั้ง dependencies (build tools, nginx, FFmpeg libs)
2. Download nginx source ตาม version ที่ติดตั้งอยู่
3. Clone `kaltura/nginx-vod-module` + apply patch แก้ปัญหา "upstream is null" ([#1551](https://github.com/kaltura/nginx-vod-module/issues/1551))
4. Build dynamic module `ngx_http_vod_module.so`
5. เขียน config ไฟล์:
   - `/etc/nginx/nginx.conf` — main config + VOD global settings
   - `/etc/nginx/conf.d/vod.conf` — mapped mode VOD server (port 8889)
   - `/etc/nginx/conf.d/local.conf` — public proxy (port 80) + URL rewrite
6. Restart nginx

---

## การใช้งาน

### วางไฟล์วิดีโอ

```bash
cp your-video.mp4 /home/files/video.mp4
```

### สร้าง JSON mapping

```bash
cat > /home/files/test.json <<'EOF'
{"sequences":[{"clips":[{"type":"source","path":"/home/files/video.mp4"}]}]}
EOF
```

### เข้าถึง Stream

| URL | คำอธิบาย |
|-----|----------|
| `http://IP/test/playlist.m3u8` | Master playlist (friendly URL) |
| `http://IP/test/video.m3u8` | Video-only playlist |
| `http://IP/test.json/playlist.m3u8` | Master playlist (with `.json`) |
| `http://IP/thumb/test-30.jpg` | Thumbnail ที่วินาทีที่ 30 |
| `http://IP/thumb/test.jpg` | Thumbnail ที่วินาทีที่ 1 (default) |

---

## Debugging

```bash
# ตรวจ JSON server
curl http://127.0.0.1:8888/test.json

# ตรวจ VOD server
curl http://127.0.0.1:8889/healthz

# ตรวจ public proxy
curl http://127.0.0.1/healthz

# ดู nginx logs
tail -f /var/log/nginx/error.log
tail -f /var/log/nginx/public-error.log

# ดู VOD status
curl http://127.0.0.1:8889/vod_status
```

---

## ไฟล์ Config ที่สำคัญ

| ไฟล์ | คำอธิบาย |
|------|----------|
| `/etc/nginx/nginx.conf` | Main config + VOD global settings |
| `/etc/nginx/conf.d/vod.conf` | VOD server (mapped mode) |
| `/etc/nginx/conf.d/local.conf` | Public proxy + URL rewrite |
| `/home/files/` | Media root directory |

---

## License

MIT
