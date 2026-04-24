# nginx-user

สร้าง Ubuntu user สำหรับ upload ไฟล์ผ่าน SFTP เข้า storage directory พร้อมตั้ง permission ให้ nginx อ่านได้

## สิ่งที่ได้หลังติดตั้ง

- Ubuntu user พร้อม password
- เพิ่มเข้ากลุ่ม `sudo` และ `www-data`
- Media directory (`/home/files`) พร้อม ACL สำหรับ group write
- เชื่อมต่อ SFTP ได้ทันที (WinSCP / FileZilla)

---

## ความต้องการ

- Ubuntu 24.04 LTS
- Root access (`sudo`)

---

## การติดตั้ง

```bash
curl -fsSL https://raw.githubusercontent.com/vdohide-core/server-storage/main/nginx/user/install.sh | sudo -E bash
```

#### ตัวเลือก

| Option | ค่าเริ่มต้น | คำอธิบาย |
|--------|-------------|----------|
| `--username NAME` | `vdohide` | ชื่อ Ubuntu user |
| `--password PASS` | `[PASSWORD]` | รหัสผ่าน |
| `--storage-path DIR` | `/home/files` | โฟลเดอร์เก็บไฟล์ |
| `--group NAME` | `www-data` | กลุ่มที่ใช้ร่วมกับ nginx |
| `--uninstall` | — | ลบ user |
| `-h, --help` | — | แสดงวิธีใช้ |

**ตัวอย่าง** — สร้าง user ชื่อ `myuser`:

```bash
curl -fsSL https://raw.githubusercontent.com/vdohide-core/server-storage/main/nginx/user/install.sh \
  | sudo -E bash -s -- --username myuser --password 'S3cureP@ss'
```

**ระบุ storage path เอง:**

```bash
curl -fsSL https://raw.githubusercontent.com/vdohide-core/server-storage/main/nginx/user/install.sh \
  | sudo -E bash -s -- \
      --username myuser \
      --password 'S3cureP@ss' \
      --storage-path /data/media
```

**ลบ user:**

```bash
curl -fsSL https://raw.githubusercontent.com/vdohide-core/server-storage/main/nginx/user/install.sh \
  | sudo -E bash -s -- --uninstall --username myuser
```

---

## สิ่งที่ script ทำ

1. สร้าง user + ตั้ง password (ถ้า user มีอยู่แล้วจะ reset password)
2. เพิ่มเข้ากลุ่ม `sudo` และ `www-data`
3. สร้าง media directory ถ้ายังไม่มี
4. ตั้ง permission `2775` + ACL (default group write inheritance)
5. ทดสอบ write access

---

## เชื่อมต่อผ่าน SFTP

| ค่า | |
|-----|----|
| **Host** | `<YOUR_SERVER_IP>` |
| **Protocol** | SFTP |
| **Port** | 22 |
| **Username** | ที่ตั้งไว้ |
| **Password** | ที่ตั้งไว้ |

Upload ไฟล์วิดีโอไปที่ `/home/files/`

---

## License

MIT
