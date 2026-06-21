#!/usr/bin/env bash
# v8: Install nginx-vod-module — nginx 1.26.3 + kaltura/nginx-vod-module (static)
# HLS, DASH, Thumbnail (FFmpeg) — sprite via server-spritesheet on disk
# Tested on Ubuntu 24.04
set -euo pipefail

# ===================== Configuration =====================
SERVER_PORT="${SERVER_PORT:-8889}"
SEGMENT_DUR="${SEGMENT_DUR:-4000}"
MEDIA_ROOT="${MEDIA_ROOT:-/home/files}"
NGX_VERSION="1.26.3"
INSTALL_PREFIX="/opt/nginx-vod"
NGX_CONF="${INSTALL_PREFIX}/conf/nginx.conf"
SKIP_BUILD="${SKIP_BUILD:-0}"   # 1 = skip compile, reuse existing binary
CONFIG_ONLY="${CONFIG_ONLY:-0}" # 1 = rewrite config + systemd only (implies SKIP_BUILD=1)
PROXY_ONLY="${PROXY_ONLY:-0}"   # 1 = rewrite port-80 local.conf only (implies CONFIG_ONLY=1)

# ====================== Helpers =========================
log(){ printf "\n\033[1;32m[INFO]\033[0m %s\n" "$*"; }
err(){ printf "\n\033[1;31m[ERR ]\033[0m %s\n" "$*"; exit 1; }
need_root(){ [[ $EUID -eq 0 ]] || err "Run as root (sudo)"; }

ensure_mime_types(){
  install -d -m 0755 "${INSTALL_PREFIX}/conf"
  if [[ -f "${INSTALL_PREFIX}/conf/mime.types" ]]; then
    return 0
  fi
  for src in \
    "${WORKDIR}/nginx-${NGX_VERSION}/conf/mime.types" \
    /usr/share/nginx/mime.types \
    /etc/nginx/mime.types; do
    if [[ -f "${src}" ]]; then
      cp -f "${src}" "${INSTALL_PREFIX}/conf/mime.types"
      log "mime.types copied from ${src}"
      return 0
    fi
  done
  err "mime.types not found — install nginx-common or run full build first"
}

vod_nginx_test(){
  ensure_mime_types
  log "Testing VOD nginx configuration..."
  if ! "${INSTALL_PREFIX}/sbin/nginx" -t -c "${NGX_CONF}" 2>&1; then
    err "nginx -t failed — see error above (${NGX_CONF})"
  fi
}

pick_cache_sizes(){
  local mem_mb
  mem_mb="$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)"
  if [[ "${mem_mb}" -lt 4096 ]]; then
    VOD_METADATA_CACHE="${VOD_METADATA_CACHE:-256m}"
    VOD_RESPONSE_CACHE="${VOD_RESPONSE_CACHE:-128m}"
    VOD_MAPPING_CACHE="${VOD_MAPPING_CACHE:-64m}"
    log "RAM ${mem_mb}MB — using small vod caches (${VOD_METADATA_CACHE}/${VOD_RESPONSE_CACHE}/${VOD_MAPPING_CACHE})"
  else
    VOD_METADATA_CACHE="${VOD_METADATA_CACHE:-2048m}"
    VOD_RESPONSE_CACHE="${VOD_RESPONSE_CACHE:-512m}"
    VOD_MAPPING_CACHE="${VOD_MAPPING_CACHE:-256m}"
  fi
}

# ====================== Main ===========================
need_root
[[ "${PROXY_ONLY}" == "1" ]] && CONFIG_ONLY=1
[[ "${CONFIG_ONLY}" == "1" ]] && SKIP_BUILD=1

WORKDIR="${HOME}/build/nginx-vod"
mkdir -p "${WORKDIR}"

log "Installing dependencies..."
apt update
if [[ "${SKIP_BUILD}" == "1" ]]; then
  DEBIAN_FRONTEND=noninteractive apt -y install \
    curl ca-certificates nginx nginx-common
else
  DEBIAN_FRONTEND=noninteractive apt -y install \
    build-essential git curl ca-certificates \
    nginx nginx-common \
    libpcre2-dev zlib1g-dev libssl-dev \
    libxml2-dev libxslt1-dev libgd-dev \
    libaio-dev \
    libavcodec-dev libavformat-dev libavutil-dev libswscale-dev libavfilter-dev \
    nload
fi

# Stop restart loop before rewriting config
systemctl stop nginx-vod 2>/dev/null || true
systemctl reset-failed nginx-vod 2>/dev/null || true

if [[ "${PROXY_ONLY}" == "1" ]]; then
  [[ -f "${INSTALL_PREFIX}/sbin/nginx" ]] || err "PROXY_ONLY=1 but ${INSTALL_PREFIX}/sbin/nginx missing"
  install -d -m 0755 /etc/nginx/conf.d
  log "PROXY_ONLY=1 — skip vod rebuild, deploy port 80 proxy only"
else
  if [[ "${SKIP_BUILD}" != "1" ]]; then
  cd "${WORKDIR}"

  # Download nginx source
  if [[ ! -f "nginx-${NGX_VERSION}.tar.gz" ]]; then
    log "Downloading nginx-${NGX_VERSION} source..."
    curl -fsSLo "nginx-${NGX_VERSION}.tar.gz" \
      "https://nginx.org/download/nginx-${NGX_VERSION}.tar.gz"
  fi
  rm -rf "nginx-${NGX_VERSION}"
  tar xzf "nginx-${NGX_VERSION}.tar.gz"

  # Clone upstream Kaltura nginx-vod-module
  log "Cloning kaltura/nginx-vod-module..."
  rm -rf nginx-vod-module
  git clone --depth=1 https://github.com/kaltura/nginx-vod-module.git

  # Build nginx + vod module (STATIC, not dynamic)
  log "Building nginx ${NGX_VERSION} with vod module (static)..."
  cd "nginx-${NGX_VERSION}"
  ./configure \
    --prefix="${INSTALL_PREFIX}" \
    --sbin-path="${INSTALL_PREFIX}/sbin/nginx" \
    --conf-path="${NGX_CONF}" \
    --error-log-path=/var/log/nginx/vod-error.log \
    --http-log-path=/var/log/nginx/vod-access.log \
    --pid-path=/run/nginx-vod.pid \
    --with-http_ssl_module \
    --with-http_sub_module \
    --with-http_gzip_static_module \
    --with-threads \
    --with-file-aio \
    --add-module=../nginx-vod-module

  make -j"$(nproc)"
  make install

  [[ -f "${INSTALL_PREFIX}/sbin/nginx" ]] || err "Build failed"
  if ! grep -q ngx_http_vod_module "${WORKDIR}/nginx-${NGX_VERSION}/objs/ngx_modules.c" 2>/dev/null; then
    err "vod module was not compiled — check ../nginx-vod-module path"
  fi
  log "nginx binary: ${INSTALL_PREFIX}/sbin/nginx"
  "${INSTALL_PREFIX}/sbin/nginx" -V 2>&1 | head -5
  if ! "${INSTALL_PREFIX}/sbin/nginx" -V 2>&1 | grep -qi ffmpeg; then
    log "⚠️  FFmpeg not linked — vod thumb will not work (check libavcodec-dev)"
  fi
  else
    [[ -f "${INSTALL_PREFIX}/sbin/nginx" ]] || err "SKIP_BUILD=1 but ${INSTALL_PREFIX}/sbin/nginx missing"
    log "Skipping build — using ${INSTALL_PREFIX}/sbin/nginx"
  fi

  # Prepare directories
log "Preparing directories..."
install -d -m 0755 /var/log/nginx
install -d -m 0755 "${MEDIA_ROOT}"
install -d -m 0755 /var/cache/nginx/vod
chown -R www-data:www-data "${MEDIA_ROOT}" /var/cache/nginx/vod

ensure_mime_types
pick_cache_sizes

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
  include ${INSTALL_PREFIX}/conf/mime.types;
  default_type application/octet-stream;

  sendfile on;
  tcp_nopush on;
  tcp_nodelay on;
  keepalive_timeout 60;

  gzip on;
  gzip_types application/vnd.apple.mpegurl application/dash+xml text/xml text/vtt application/json;

  # VOD global settings (aio on — kaltura default; needs --with-file-aio)
  aio on;
  vod_initial_read_size 16m;
  vod_max_metadata_size 512m;
  vod_metadata_cache metadata_cache ${VOD_METADATA_CACHE};
  vod_response_cache response_cache ${VOD_RESPONSE_CACHE};
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
    vod_mapping_cache mapping_cache ${VOD_MAPPING_CACHE};

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

    # Thumbnail capture (requires FFmpeg at build time)
    location /thumb/ {
      vod thumb;
      vod_thumb_accurate_positioning off;

      add_header Access-Control-Allow-Headers '*';
      add_header Access-Control-Allow-Methods 'GET, HEAD, OPTIONS';
      add_header Access-Control-Allow-Origin '*';
      add_header Cache-Control 'public, max-age=31536000, immutable' always;
    }

    location /vod_status {
      vod_status;
      access_log off;
    }

    access_log /var/log/nginx/vod-access.log;
    error_log /var/log/nginx/vod-error.log info;
  }
}
CONF

# ── Config test BEFORE systemd (fail fast with visible error) ──
vod_nginx_test

# Free port / stale pid
if [[ -f /run/nginx-vod.pid ]]; then
  old_pid="$(cat /run/nginx-vod.pid 2>/dev/null || true)"
  if [[ -n "${old_pid}" ]] && kill -0 "${old_pid}" 2>/dev/null; then
    log "Stopping stale nginx-vod (pid ${old_pid})..."
    kill -QUIT "${old_pid}" 2>/dev/null || true
    sleep 1
  fi
  rm -f /run/nginx-vod.pid
fi
if ss -tlnp 2>/dev/null | grep -q ":${SERVER_PORT} "; then
  log "⚠️  Port ${SERVER_PORT} still in use:"
  ss -tlnp | grep ":${SERVER_PORT} " || true
  err "Port ${SERVER_PORT} is busy — stop the other process first"
fi

# =================== Systemd service ===================
log "Creating systemd service..."
cat >/etc/systemd/system/nginx-vod.service <<SVC
[Unit]
Description=nginx VOD server (${NGX_VERSION} + vod module)
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
PIDFile=/run/nginx-vod.pid
ExecStartPre=${INSTALL_PREFIX}/sbin/nginx -t -c ${NGX_CONF}
ExecStart=${INSTALL_PREFIX}/sbin/nginx -c ${NGX_CONF}
ExecReload=/bin/kill -s HUP \$MAINPID
ExecStop=/bin/kill -s QUIT \$MAINPID
LimitNOFILE=65535
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
SVC

# Stop if already running
"${INSTALL_PREFIX}/sbin/nginx" -s stop -c "${NGX_CONF}" 2>/dev/null || true

systemctl daemon-reload
systemctl enable nginx-vod
if ! systemctl start nginx-vod; then
  log "❌ systemctl start failed — diagnostics:"
  "${INSTALL_PREFIX}/sbin/nginx" -t -c "${NGX_CONF}" 2>&1 || true
  journalctl -xeu nginx-vod.service --no-pager | tail -25 || true
  err "nginx-vod failed to start"
fi
log "✅ nginx-vod service started"

fi  # end PROXY_ONLY skip (vod setup)

# =================== Write local.conf (public proxy) ===================
install -d -m 0755 /etc/nginx/conf.d
log "Writing /etc/nginx/conf.d/local.conf..."
cat >/etc/nginx/conf.d/local.conf <<'NGX'
# Public proxy server (port 80)
server {
  listen 80 default_server;
  listen [::]:80 default_server;
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

  # Pattern 7: Thumbnail proxy
  # /test/thumb-5000.jpg -> /thumb/test.json/thumb-5000.jpg
  # /test/thumb-5000-w320.jpg -> /thumb/test.json/thumb-5000-w320.jpg
  location ~ ^/([^/]+)/(thumb-[0-9].*\.jpg)$ {
    if ($request_method = OPTIONS) {
      add_header Access-Control-Allow-Origin * always;
      add_header Access-Control-Allow-Headers '*' always;
      add_header Access-Control-Allow-Methods 'GET, HEAD, OPTIONS' always;
      add_header Content-Length 0;
      add_header Content-Type text/plain;
      return 204;
    }

    proxy_http_version 1.1;
    proxy_set_header Connection "";
    proxy_set_header Host $host;
    proxy_pass http://127.0.0.1:8889/thumb/$1.json/$2;

    proxy_hide_header Access-Control-Allow-Origin;
    proxy_hide_header Access-Control-Allow-Headers;
    proxy_hide_header Access-Control-Allow-Methods;

    add_header Access-Control-Allow-Origin '*' always;
    add_header Cache-Control 'public, max-age=31536000, immutable' always;
    add_header Content-Type 'image/jpeg' always;
  }

  # Pattern 8: Catch-all for other files (MUST be LAST)
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

# Default Ubuntu site also listens on :80 — disable it or our proxy never matches
if [[ -e /etc/nginx/sites-enabled/default ]]; then
  log "Disabling default nginx site (conflicts with VOD public proxy)..."
  rm -f /etc/nginx/sites-enabled/default
fi

# Test and restart system nginx (package installed above)
log "Testing system nginx configuration..."
if ! nginx -t 2>&1; then
  err "system nginx -t failed — check /etc/nginx/conf.d/local.conf"
fi

log "Restarting system nginx..."
systemctl enable nginx 2>/dev/null || true
systemctl restart nginx

if ! curl -fsS "http://127.0.0.1/healthz" 2>/dev/null | grep -q '^ok'; then
  err "public proxy not responding on :80/healthz — is /etc/nginx/conf.d/local.conf loaded?"
fi
log "✅ public proxy (port 80) healthz ok"

# =================== Final verification ===================
log "Verifying services..."
sleep 2

# Check nginx-vod is running
if systemctl is-active --quiet nginx-vod; then
  log "✅ nginx-vod (port ${SERVER_PORT}) is running"
elif [[ "${PROXY_ONLY}" == "1" ]]; then
  log "⚠️  nginx-vod not running (PROXY_ONLY — start it manually if needed)"
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
log "  6. Thumbnail:"
log "     Internal:  http://YOUR_IP:${SERVER_PORT}/thumb/test.json/thumb-5000.jpg"
log "     Public:    http://YOUR_IP/test/thumb-5000.jpg"
log "     With width: http://YOUR_IP/test/thumb-10000-w320.jpg"
log ""
log "  7. Re-run without rebuild (fix config/systemd only):"
log "     CONFIG_ONLY=1 bash install.sh"
log ""
log "  8. Deploy port 80 proxy only (vod already running on :8889):"
log "     PROXY_ONLY=1 bash install.sh"
log ""
