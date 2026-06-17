#!/usr/bin/env bash
# v4: Install nginx-vod-module — nginx 1.26.3 from source + static module
# Fixes: FFmpeg 6.x crash, "upstream is null" crash, ABI mismatch
# Tested on Ubuntu 24.04
set -euo pipefail

# ===================== Configuration =====================
SERVER_PORT="${SERVER_PORT:-8889}"
SEGMENT_DUR="${SEGMENT_DUR:-4000}"
MEDIA_ROOT="${MEDIA_ROOT:-/home/files}"
NGX_VERSION="1.26.3"
INSTALL_PREFIX="/opt/nginx-vod"

# ====================== Helpers =========================
log(){ printf "\n\033[1;32m[INFO]\033[0m %s\n" "$*"; }
err(){ printf "\n\033[1;31m[ERR ]\033[0m %s\n" "$*"; exit 1; }
need_root(){ [[ $EUID -eq 0 ]] || err "Run as root (sudo)"; }

# ====================== Main ===========================
need_root

log "Installing dependencies..."
apt update
DEBIAN_FRONTEND=noninteractive apt -y install \
  build-essential git curl ca-certificates \
  libpcre2-dev zlib1g-dev libssl-dev \
  libxml2-dev libxslt1-dev libgd-dev \
  nload

WORKDIR="${HOME}/build/nginx-vod"
mkdir -p "${WORKDIR}"
cd "${WORKDIR}"

# Download nginx source
if [[ ! -f "nginx-${NGX_VERSION}.tar.gz" ]]; then
  log "Downloading nginx-${NGX_VERSION} source..."
  curl -fsSLo "nginx-${NGX_VERSION}.tar.gz" \
    "https://nginx.org/download/nginx-${NGX_VERSION}.tar.gz"
fi
rm -rf "nginx-${NGX_VERSION}"
tar xzf "nginx-${NGX_VERSION}.tar.gz"

# Clone Kaltura nginx-vod-module (latest)
log "Cloning Kaltura nginx-vod-module..."
rm -rf nginx-vod-module
git clone --depth=1 https://github.com/kaltura/nginx-vod-module.git

# Hide FFmpeg headers to avoid linking (FFmpeg 6.x causes segfault)
log "Hiding FFmpeg headers to prevent linking..."
for d in libavcodec libavformat libavutil libswscale libavfilter; do
  [[ -d "/usr/include/x86_64-linux-gnu/$d" ]] && \
    mv "/usr/include/x86_64-linux-gnu/$d" "/usr/include/x86_64-linux-gnu/${d}.bak" || true
done

# Build nginx + vod module (STATIC, not dynamic)
log "Building nginx ${NGX_VERSION} with vod module (static)..."
cd "nginx-${NGX_VERSION}"
./configure \
  --prefix="${INSTALL_PREFIX}" \
  --sbin-path="${INSTALL_PREFIX}/sbin/nginx" \
  --conf-path="${INSTALL_PREFIX}/conf/nginx.conf" \
  --error-log-path=/var/log/nginx/vod-error.log \
  --http-log-path=/var/log/nginx/vod-access.log \
  --pid-path=/run/nginx-vod.pid \
  --with-http_ssl_module \
  --with-http_sub_module \
  --with-http_gzip_static_module \
  --with-threads \
  --add-module=../nginx-vod-module

make -j"$(nproc)"
make install

# Restore FFmpeg headers
log "Restoring FFmpeg headers..."
for d in libavcodec libavformat libavutil libswscale libavfilter; do
  [[ -d "/usr/include/x86_64-linux-gnu/${d}.bak" ]] && \
    mv "/usr/include/x86_64-linux-gnu/${d}.bak" "/usr/include/x86_64-linux-gnu/$d" || true
done

[[ -f "${INSTALL_PREFIX}/sbin/nginx" ]] || err "Build failed"
log "nginx binary: ${INSTALL_PREFIX}/sbin/nginx"
${INSTALL_PREFIX}/sbin/nginx -V 2>&1 | head -3

# Prepare directories
log "Preparing directories..."
install -d -m 0755 "${MEDIA_ROOT}"
install -d -m 0755 /var/cache/nginx/vod
chown -R www-data:www-data "${MEDIA_ROOT}" /var/cache/nginx/vod

# =================== Disable system nginx vod ===================
# If system nginx has vod.conf, disable it to free port 8889
if [[ -f /etc/nginx/conf.d/vod.conf ]]; then
  log "Disabling system nginx vod.conf..."
  mv /etc/nginx/conf.d/vod.conf /etc/nginx/conf.d/vod.conf.disabled
  systemctl restart nginx 2>/dev/null || true
fi

# =================== Write VOD nginx config ===================
log "Writing ${INSTALL_PREFIX}/conf/nginx.conf..."
cat >"${INSTALL_PREFIX}/conf/nginx.conf" <<CONF
worker_processes auto;
pid /run/nginx-vod.pid;
error_log /var/log/nginx/vod-error.log info;

events {
  worker_connections 4096;
}

http {
  include /etc/nginx/mime.types;
  default_type application/octet-stream;

  sendfile on;
  tcp_nopush on;
  tcp_nodelay on;
  keepalive_timeout 60;

  gzip on;
  gzip_types application/vnd.apple.mpegurl application/dash+xml text/xml text/vtt application/json;

  # VOD global settings
  aio threads;
  vod_initial_read_size 16m;
  vod_max_metadata_size 512m;
  vod_metadata_cache metadata_cache 2048m;
  vod_response_cache response_cache 512m;
  vod_output_buffer_pool 4m 64;
  vod_performance_counters perf_counters;
  vod_last_modified 'Sun, 19 Nov 2000 08:52:00 GMT';
  vod_last_modified_types *;

  # Support for large files (12-20GB, 12+ hours)
  vod_max_frame_count 5000000;

  vod_segment_duration ${SEGMENT_DUR};
  vod_manifest_segment_durations_mode accurate;
  vod_segment_count_policy last_rounded;

  vod_force_continuous_timestamps on;
  vod_ignore_edit_list on;

  # DNS resolver
  resolver 1.1.1.1 1.0.0.1 valid=300s;
  resolver_timeout 5s;

  # Log format
  log_format vod_log '\$remote_addr "\$request" \$status vod:\$vod_status';
  access_log /var/log/nginx/vod-access.log vod_log;

  upstream jsonserver {
    server 127.0.0.1:8888;
    keepalive 16;
  }

  server {
    listen ${SERVER_PORT};
    server_name _;

    # vod mode configuration
    vod_mode mapped;
    vod_upstream_location /json;

    # mapping cache
    vod_mapping_cache mapping_cache 256m;

    # Support for large files
    vod_max_mapping_response_size 128m;

    # gzip manifests
    gzip on;
    gzip_types application/vnd.apple.mpegurl application/dash+xml;

    # file handle caching
    open_file_cache max=1000 inactive=5m;
    open_file_cache_valid 2m;
    open_file_cache_min_uses 1;
    open_file_cache_errors on;

    # Client settings for large files
    client_body_buffer_size 256k;
    client_max_body_size 500m;
    client_body_timeout 90s;

    location = /healthz {
      return 200 "ok\n";
    }

    # JSON mapping - proxy to local JSON server
    location ^~ /json/ {
      internal;
      rewrite ^/json/[^/]+/(.*)\$ /\$1 break;
      proxy_pass http://jsonserver;
      proxy_http_version 1.1;
      proxy_set_header Host \$http_host;
      proxy_set_header Connection "";

      # Timeouts and buffers for large files
      proxy_connect_timeout 60s;
      proxy_send_timeout 90s;
      proxy_read_timeout 90s;
      proxy_buffer_size 128k;
      proxy_buffers 16 128k;
      proxy_busy_buffers_size 256k;
    }

    # HLS streaming
    location /hls/ {
      vod hls;
      vod_hls_output_iframes_playlist off;
      vod_force_continuous_timestamps on;
      vod_ignore_edit_list on;

      add_header Access-Control-Allow-Headers '*';
      add_header Access-Control-Expose-Headers 'Server,range,Content-Length,Content-Range';
      add_header Access-Control-Allow-Methods 'GET, HEAD, OPTIONS';
      add_header Access-Control-Allow-Origin '*';

      # Playlists (.m3u8)
      location ~ \.m3u8\$ {
        vod hls;
        vod_hls_output_iframes_playlist off;
        vod_force_continuous_timestamps on;
        vod_ignore_edit_list on;
        add_header Cache-Control "public, max-age=3600" always;
        add_header Access-Control-Allow-Origin '*' always;
        expires 1h;
      }

      # Segments (.ts)
      location ~ \.ts\$ {
        vod hls;
        vod_force_continuous_timestamps on;
        vod_ignore_edit_list on;
        add_header Cache-Control "public, max-age=31536000, immutable" always;
        add_header Access-Control-Allow-Origin '*' always;
        expires 1y;
      }

      expires 1h;
    }

    # DASH streaming
    location /dash/ {
      vod dash;
      vod_force_continuous_timestamps on;
      vod_ignore_edit_list on;

      add_header Access-Control-Allow-Headers '*';
      add_header Access-Control-Expose-Headers 'Server,range,Content-Length,Content-Range';
      add_header Access-Control-Allow-Methods 'GET, HEAD, OPTIONS';
      add_header Access-Control-Allow-Origin '*';

      location ~ \.mpd\$ {
        vod dash;
        vod_force_continuous_timestamps on;
        vod_ignore_edit_list on;
        add_header Cache-Control "public, max-age=3600" always;
        add_header Access-Control-Allow-Origin '*' always;
        expires 1h;
      }

      location ~ ^/dash/.*/init.*\.m[p4][4s]\$ {
        vod dash;
        vod_force_continuous_timestamps on;
        vod_ignore_edit_list on;
        add_header Cache-Control "public, max-age=31536000, immutable" always;
        add_header Access-Control-Allow-Origin '*' always;
        expires 1y;
      }

      location ~ \.m4s\$ {
        vod dash;
        vod_force_continuous_timestamps on;
        vod_ignore_edit_list on;
        add_header Cache-Control "public, max-age=31536000, immutable" always;
        add_header Access-Control-Allow-Origin '*' always;
        expires 1y;
      }

      expires 1h;
    }

    # Thumbnail - disabled (requires FFmpeg 4.x)
    # To enable: rebuild with FFmpeg 4.4 from source
    # location /thumb/ {
    #   vod thumb;
    # }

    location /vod_status {
      vod_status;
      access_log off;
    }

    access_log /var/log/nginx/vod-access.log;
    error_log /var/log/nginx/vod-error.log info;
  }
}
CONF

# =================== Systemd service ===================
log "Creating systemd service..."
cat >/etc/systemd/system/nginx-vod.service <<'SVC'
[Unit]
Description=nginx VOD server (1.26.3 + vod module)
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
PIDFile=/run/nginx-vod.pid
ExecStartPre=/opt/nginx-vod/sbin/nginx -t
ExecStart=/opt/nginx-vod/sbin/nginx
ExecReload=/bin/kill -s HUP $MAINPID
ExecStop=/bin/kill -s QUIT $MAINPID
LimitNOFILE=65535
PrivateTmp=true
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
SVC

# Stop if already running
${INSTALL_PREFIX}/sbin/nginx -s stop 2>/dev/null || true

systemctl daemon-reload
systemctl enable nginx-vod
systemctl start nginx-vod

# =================== Write local.conf (public proxy) ===================
log "Writing /etc/nginx/conf.d/local.conf..."
cat >/etc/nginx/conf.d/local.conf <<'NGX'
# Public proxy server (port 80)
server {
  listen 80;
  server_name _;

  # Default index — fake OSS error
  location = / {
    default_type application/xml;
    return 404 '<?xml version="1.0" encoding="UTF-8"?>\n<Error>\n  <Code>NoSuchKey</Code>\n  <Message>The specified key does not exist.</Message>\n  <RequestId>69870680B0CAA23639B92A8C</RequestId>\n  <HostId>surrit.oss-eu-central-1.aliyuncs.com</HostId>\n  <Key>/</Key>\n  <EC>0026-00000001</EC>\n  <RecommendDoc>https://api.alibabacloud.com/troubleshoot?q=0026-00000001</RecommendDoc>\n</Error>';
  }

  # Custom 404 — fake OSS error
  error_page 404 /custom_404;
  location = /custom_404 {
    internal;
    default_type application/xml;
    return 404 '<?xml version="1.0" encoding="UTF-8"?>\n<Error>\n  <Code>NoSuchKey</Code>\n  <Message>The specified key does not exist.</Message>\n  <RequestId>69870680B0CAA23639B92A8C</RequestId>\n  <HostId>surrit.oss-eu-central-1.aliyuncs.com</HostId>\n  <Key>$request_uri</Key>\n  <EC>0026-00000001</EC>\n  <RecommendDoc>https://api.alibabacloud.com/troubleshoot?q=0026-00000001</RecommendDoc>\n</Error>';
  }

  # Static files from /home/files
  location /static/ {
    alias /home/files/;
    autoindex on;

    add_header Access-Control-Allow-Origin * always;
  }

  # Proxy HLS streaming - support both /test.json/playlist.m3u8 and /test/playlist.m3u8
  # Pattern 1: /filename.json/playlist.m3u8 -> /hls/filename.json/master.m3u8
  location ~ ^/([^/]+\.json)/playlist\.m3u8$ {
    # Handle OPTIONS
    if ($request_method = OPTIONS) {
      add_header Access-Control-Allow-Origin * always;
      add_header Access-Control-Allow-Headers '*' always;
      add_header Access-Control-Allow-Methods 'GET, HEAD, OPTIONS' always;
      add_header Access-Control-Expose-Headers 'Server,range,Content-Length,Content-Range' always;
      add_header Content-Length 0;
      add_header Content-Type text/plain;
      return 204;
    }

    proxy_http_version 1.1;
    proxy_set_header Connection "";
    proxy_set_header Host $host;
    proxy_set_header Accept-Encoding "";
    proxy_pass http://127.0.0.1:8889/hls/$1/master.m3u8;

    proxy_buffering on;
    proxy_buffer_size 4k;
    proxy_buffers 8 4k;

    proxy_hide_header Access-Control-Allow-Origin;
    proxy_hide_header Access-Control-Allow-Headers;
    proxy_hide_header Access-Control-Allow-Methods;
    proxy_hide_header Access-Control-Expose-Headers;

    add_header Access-Control-Allow-Origin * always;
    add_header Access-Control-Allow-Headers '*' always;
    add_header Access-Control-Allow-Methods 'GET, HEAD, OPTIONS' always;
    add_header Access-Control-Expose-Headers 'Server,range,Content-Length,Content-Range' always;

    sub_filter_types application/vnd.apple.mpegurl;
    sub_filter '/hls/' '/';
    sub_filter '/index-v1-a1.m3u8' '/video.m3u8';
    sub_filter_once off;
  }

  # Pattern 2: /filename.json/index.m3u8 or any .m3u8
  location ~ ^/([^/]+\.json)/(.+\.m3u8)$ {
    if ($request_method = OPTIONS) {
      add_header Access-Control-Allow-Origin * always;
      add_header Access-Control-Allow-Headers '*' always;
      add_header Access-Control-Allow-Methods 'GET, HEAD, OPTIONS' always;
      add_header Access-Control-Expose-Headers 'Server,range,Content-Length,Content-Range' always;
      add_header Content-Length 0;
      add_header Content-Type text/plain;
      return 204;
    }

    proxy_http_version 1.1;
    proxy_set_header Connection "";
    proxy_set_header Host $host;
    proxy_pass http://127.0.0.1:8889/hls/$1/$2;

    proxy_buffering on;
    proxy_buffer_size 4k;
    proxy_buffers 8 4k;

    proxy_hide_header Access-Control-Allow-Origin;
    proxy_hide_header Access-Control-Allow-Headers;
    proxy_hide_header Access-Control-Allow-Methods;
    proxy_hide_header Access-Control-Expose-Headers;

    add_header Access-Control-Allow-Origin * always;
    add_header Access-Control-Allow-Headers '*' always;
    add_header Access-Control-Allow-Methods 'GET, HEAD, OPTIONS' always;
    add_header Access-Control-Expose-Headers 'Server,range,Content-Length,Content-Range' always;

    sub_filter_types application/vnd.apple.mpegurl;
    sub_filter '/hls/' '/';
    sub_filter_once off;
  }

  # Pattern 3: /filename.json/segments (ts, m4s, etc.)
  location ~ ^/([^/]+\.json)/(.+)$ {
    if ($request_method = OPTIONS) {
      add_header Access-Control-Allow-Origin * always;
      add_header Access-Control-Allow-Headers '*' always;
      add_header Access-Control-Allow-Methods 'GET, HEAD, OPTIONS' always;
      add_header Access-Control-Expose-Headers 'Server,range,Content-Length,Content-Range' always;
      add_header Content-Length 0;
      add_header Content-Type text/plain;
      return 204;
    }

    proxy_http_version 1.1;
    proxy_set_header Connection "";
    proxy_set_header Host $host;
    proxy_pass http://127.0.0.1:8889/hls/$1/$2;

    proxy_hide_header Access-Control-Allow-Origin;
    proxy_hide_header Access-Control-Allow-Headers;
    proxy_hide_header Access-Control-Allow-Methods;
    proxy_hide_header Access-Control-Expose-Headers;

    add_header Access-Control-Allow-Origin * always;
    add_header Access-Control-Allow-Headers '*' always;
    add_header Access-Control-Allow-Methods 'GET, HEAD, OPTIONS' always;
    add_header Access-Control-Expose-Headers 'Server,range,Content-Length,Content-Range' always;
  }

  # Pattern 4: Friendly URLs without .json extension
  # /test/master.m3u8 -> /hls/test.json/master.m3u8
  location ~ ^/([^/]+)/master\.m3u8$ {
    if ($request_method = OPTIONS) {
      add_header Access-Control-Allow-Origin * always;
      add_header Access-Control-Allow-Headers '*' always;
      add_header Access-Control-Allow-Methods 'GET, HEAD, OPTIONS' always;
      add_header Access-Control-Expose-Headers 'Server,range,Content-Length,Content-Range' always;
      add_header Content-Length 0;
      add_header Content-Type text/plain;
      return 204;
    }

    proxy_http_version 1.1;
    proxy_set_header Connection "";
    proxy_set_header Host $host;
    proxy_set_header Accept-Encoding "";
    proxy_pass http://127.0.0.1:8889/hls/$1.json/master.m3u8;

    proxy_buffering on;
    proxy_buffer_size 4k;
    proxy_buffers 8 4k;

    proxy_hide_header Access-Control-Allow-Origin;
    proxy_hide_header Access-Control-Allow-Headers;
    proxy_hide_header Access-Control-Allow-Methods;
    proxy_hide_header Access-Control-Expose-Headers;

    add_header Access-Control-Allow-Origin * always;
    add_header Access-Control-Allow-Headers '*' always;
    add_header Access-Control-Allow-Methods 'GET, HEAD, OPTIONS' always;
    add_header Access-Control-Expose-Headers 'Server,range,Content-Length,Content-Range' always;

    sub_filter_types application/vnd.apple.mpegurl text/plain;
    sub_filter '/hls/' '/';
    sub_filter '.json/index-v1-a1.m3u8' '/video.m3u8';
    sub_filter_once off;
  }

  # Pattern 5: /test/video.m3u8 -> /hls/test.json/index-v1-a1.m3u8
  location ~ ^/([^/]+)/video\.m3u8$ {
    if ($request_method = OPTIONS) {
      add_header Access-Control-Allow-Origin * always;
      add_header Access-Control-Allow-Headers '*' always;
      add_header Access-Control-Allow-Methods 'GET, HEAD, OPTIONS' always;
      add_header Access-Control-Expose-Headers 'Server,range,Content-Length,Content-Range' always;
      add_header Content-Length 0;
      add_header Content-Type text/plain;
      return 204;
    }

    proxy_http_version 1.1;
    proxy_set_header Connection "";
    proxy_set_header Host $host;
    proxy_set_header Accept-Encoding "";
    proxy_pass http://127.0.0.1:8889/hls/$1.json/index-v1-a1.m3u8;

    proxy_buffering on;
    proxy_buffer_size 4k;
    proxy_buffers 8 4k;

    proxy_hide_header Access-Control-Allow-Origin;
    proxy_hide_header Access-Control-Allow-Headers;
    proxy_hide_header Access-Control-Allow-Methods;
    proxy_hide_header Access-Control-Expose-Headers;

    add_header Access-Control-Allow-Origin * always;
    add_header Access-Control-Allow-Headers '*' always;
    add_header Access-Control-Allow-Methods 'GET, HEAD, OPTIONS' always;
    add_header Access-Control-Expose-Headers 'Server,range,Content-Length,Content-Range' always;

    sub_filter_types application/vnd.apple.mpegurl text/plain;
    sub_filter '/hls/' '/';
    sub_filter '.json/seg-' '/v-';
    sub_filter '-v1-a1.ts' '.jpeg';
    sub_filter_once off;
  }

  # Pattern 6: /xxx/v-2.jpeg -> /hls/xxx.json/seg-2-v1-a1.ts
  location ~ ^/([^/]+)/v-(\d+)\.jpeg$ {
    limit_rate 3m;
    limit_rate_after 100k;

    if ($request_method = OPTIONS) {
      add_header Access-Control-Allow-Origin * always;
      add_header Access-Control-Allow-Headers '*' always;
      add_header Access-Control-Allow-Methods 'GET, HEAD, OPTIONS' always;
      add_header Access-Control-Expose-Headers 'Server,range,Content-Length,Content-Range' always;
      add_header Content-Length 0;
      add_header Content-Type text/plain;
      return 204;
    }

    proxy_http_version 1.1;
    proxy_set_header Connection "";
    proxy_set_header Host $host;
    proxy_pass http://127.0.0.1:8889/hls/$1.json/seg-$2-v1-a1.ts;

    proxy_hide_header Access-Control-Allow-Origin;
    proxy_hide_header Access-Control-Allow-Headers;
    proxy_hide_header Access-Control-Allow-Methods;
    proxy_hide_header Access-Control-Expose-Headers;
    proxy_hide_header Content-Type;
    proxy_hide_header Cache-Control;
    proxy_hide_header Expires;
    proxy_hide_header last-modified;
    proxy_hide_header Server;
    proxy_hide_header Timing-Allow-Origin;
    proxy_hide_header Vary;
    proxy_hide_header Accept-Ranges;
    proxy_hide_header Connection;
    proxy_hide_header Date;

    add_header Content-Type 'image/jpeg' always;
    add_header Accept-Ranges 'bytes' always;
    add_header Access-Control-Allow-Origin '*' always;
    add_header Access-Control-Allow-Credentials 'false' always;
    add_header Cache-Control 'public, max-age=31536000, immutable' always;
    add_header Timing-Allow-Origin '*' always;
    add_header Vary 'Accept-Encoding' always;
    server_tokens off;
  }

  # Pattern 7: Catch-all for other files (MUST be AFTER Pattern 6)
  # /test/anything -> /hls/test.json/anything
  location ~ ^/([^/]+)/(.*)$ {
    if ($request_method = OPTIONS) {
      add_header Access-Control-Allow-Origin * always;
      add_header Access-Control-Allow-Headers '*' always;
      add_header Access-Control-Allow-Methods 'GET, HEAD, OPTIONS' always;
      add_header Access-Control-Expose-Headers 'Server,range,Content-Length,Content-Range' always;
      add_header Content-Length 0;
      add_header Content-Type text/plain;
      return 204;
    }

    proxy_http_version 1.1;
    proxy_set_header Connection "";
    proxy_set_header Host $host;
    proxy_set_header Accept-Encoding "";
    proxy_pass http://127.0.0.1:8889/hls/$1.json/$2;

    proxy_buffering on;
    proxy_buffer_size 4k;
    proxy_buffers 8 4k;

    proxy_hide_header Access-Control-Allow-Origin;
    proxy_hide_header Access-Control-Allow-Headers;
    proxy_hide_header Access-Control-Allow-Methods;
    proxy_hide_header Access-Control-Expose-Headers;

    add_header Access-Control-Allow-Origin * always;
    add_header Access-Control-Allow-Headers '*' always;
    add_header Access-Control-Allow-Methods 'GET, HEAD, OPTIONS' always;
    add_header Access-Control-Expose-Headers 'Server,range,Content-Length,Content-Range' always;

    sub_filter_types application/vnd.apple.mpegurl text/plain;
    sub_filter '/hls/' '/';
    sub_filter '.json/' '/';
    sub_filter 'seg-' 'v-';
    sub_filter '-v1-a1.ts' '.jpeg';
    sub_filter_once off;
  }

  location = /healthz {
    return 200 "ok\n";
  }

  access_log /var/log/nginx/public.log;
  error_log /var/log/nginx/public-error.log warn;
}
NGX

# Apply variable substitutions to local.conf
sed -i "s|127.0.0.1:8889|127.0.0.1:${SERVER_PORT}|g" /etc/nginx/conf.d/local.conf

# Test and restart system nginx
log "Testing system nginx configuration..."
nginx -t

log "Restarting system nginx..."
systemctl restart nginx

# =================== Final verification ===================
log "Verifying services..."
sleep 2

# Check nginx-vod is running
if systemctl is-active --quiet nginx-vod; then
  log "✅ nginx-vod (port ${SERVER_PORT}) is running"
else
  err "nginx-vod failed to start"
fi

# Check system nginx is running
if systemctl is-active --quiet nginx; then
  log "✅ system nginx (port 80) is running"
else
  log "⚠️  system nginx is not running (check /var/log/nginx/)"
fi

log ""
log "Installation complete!"
log ""
log "Architecture:"
log "  nginx-vod  (1.26.3, static module) → port ${SERVER_PORT}"
log "  nginx      (system, public proxy)   → port 80"
log ""
log "Usage:"
log "  1. Place your video file:"
log "     cp your-video.mp4 ${MEDIA_ROOT}/video.mp4"
log ""
log "  2. Create JSON mapping on your JSON server (port 8888):"
log '     {"sequences":[{"clips":[{"type":"source","path":"'"${MEDIA_ROOT}"'/video.mp4"}]}]}'
log ""
log "  3. Access HLS stream:"
log "     Internal:  http://YOUR_IP:${SERVER_PORT}/hls/test.json/master.m3u8"
log "     Public:    http://YOUR_IP/test/master.m3u8"
log ""
log "  4. Debugging:"
log "     Check JSON server:   curl http://127.0.0.1:8888/test.json"
log "     Check VOD server:    curl http://127.0.0.1:${SERVER_PORT}/healthz"
log "     Check public proxy:  curl http://127.0.0.1/healthz"
log "     VOD logs:            tail -f /var/log/nginx/vod-error.log"
log "     Public logs:         tail -f /var/log/nginx/public-error.log"
log "     VOD status:          http://YOUR_IP:${SERVER_PORT}/vod_status"
log ""
log "  5. Services:"
log "     systemctl status nginx-vod    # VOD server"
log "     systemctl status nginx        # Public proxy"
log ""
log "Note: Thumbnail (/thumb/) is disabled. To enable, rebuild with FFmpeg 4.4 from source."
