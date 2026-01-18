#!/usr/bin/env bash

# Copyright (c) 2021-2026 community-scripts ORG
# Author: Brandon Groves
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://github.com/rommapp/romm

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

APP="RomM"
ROMM_USER="romm"
ROMM_GROUP="romm"
ROMM_HOME="/opt/romm"
ROMM_BASE="/romm"
ROMM_ENV_DIR="/etc/romm"
ROMM_ENV_FILE="/etc/romm/romm.env"
ROMM_VERSION_FILE="/opt/romm/.version"
ROMM_CRED_FILE="/root/romm.creds"
ROMM_NGINX_CONF="/etc/nginx/nginx.conf"
ROMM_NGINX_SITE="/etc/nginx/conf.d/romm.conf"
ROMM_NGINX_JS_DIR="/etc/nginx/js"
ROMM_GUNICORN_LOG="/etc/romm/gunicorn-logging.conf"
ROMM_INIT_BIN="/usr/local/bin/romm-init"

msg_info "Installing Dependencies"
if ! $STD apk add --no-cache \
  bash \
  ca-certificates \
  curl \
  file \
  git \
  jq \
  libpq \
  mariadb-connector-c \
  mariadb \
  mariadb-client \
  nginx \
  nginx-mod-http-js \
  nodejs \
  npm \
  openssl \
  p7zip \
  tar \
  tzdata \
  unzip; then
  msg_error "Package installation failed."
  exit 1
fi

if ! $STD apk add --no-cache valkey; then
  msg_info "Valkey not available, installing Redis instead"
  $STD apk add --no-cache redis
  if ! command -v valkey-server >/dev/null 2>&1; then
    ln -s /usr/bin/redis-server /usr/bin/valkey-server
  fi
fi
msg_ok "Installed Dependencies"

msg_info "Installing build dependencies"
$STD apk add --no-cache --virtual .romm-build \
  build-base \
  linux-headers \
  libffi-dev \
  libpq-dev \
  mariadb-connector-c-dev \
  bzip2-dev \
  ncurses-dev \
  openssl-dev \
  readline-dev \
  sqlite-dev \
  xz-dev \
  zlib-dev
msg_ok "Installed build dependencies"

msg_info "Installing uv"
UV_TAG=$(curl -fsSL https://api.github.com/repos/astral-sh/uv/releases/latest | jq -r '.tag_name')
UV_VERSION="${UV_TAG#v}"
case "$(uname -m)" in
  x86_64) UV_ARCH="x86_64-unknown-linux-musl" ;;
  aarch64) UV_ARCH="aarch64-unknown-linux-musl" ;;
  *)
    msg_error "Unsupported architecture for uv."
    exit 1
    ;;
esac
curl -fsSL "https://github.com/astral-sh/uv/releases/download/${UV_TAG}/uv-${UV_ARCH}.tar.gz" -o /tmp/uv.tar.gz
tar -xzf /tmp/uv.tar.gz -C /tmp
if [[ -f /tmp/uv ]]; then
  install -m 0755 /tmp/uv /usr/local/bin/uv
else
  install -m 0755 /tmp/*/uv /usr/local/bin/uv
fi
rm -rf /tmp/uv.tar.gz /tmp/uv
msg_ok "Installed uv ${UV_VERSION}"

msg_info "Downloading RomM"
ROMM_RELEASE_JSON=$(curl -fsSL https://api.github.com/repos/rommapp/romm/releases/latest)
ROMM_TAG=$(echo "$ROMM_RELEASE_JSON" | jq -r '.tag_name')
ROMM_VERSION="${ROMM_TAG#v}"
ROMM_TARBALL=$(echo "$ROMM_RELEASE_JSON" | jq -r '.tarball_url')
if [[ -z "$ROMM_VERSION" || "$ROMM_VERSION" == "null" || -z "$ROMM_TARBALL" || "$ROMM_TARBALL" == "null" ]]; then
  msg_error "Unable to resolve RomM release data."
  exit 1
fi
rm -rf "$ROMM_HOME"
mkdir -p "$ROMM_HOME"
curl -fsSL "$ROMM_TARBALL" | tar -xz -C "$ROMM_HOME" --strip-components=1
echo "$ROMM_VERSION" >"$ROMM_VERSION_FILE"
msg_ok "Downloaded RomM v${ROMM_VERSION}"

msg_info "Creating RomM user"
addgroup -S "$ROMM_GROUP" >/dev/null 2>&1 || true
adduser -S -D -H -G "$ROMM_GROUP" "$ROMM_USER" >/dev/null 2>&1 || true
msg_ok "Created RomM user"

msg_info "Configuring MariaDB"
mysql_install_db --user=mysql --basedir=/usr --datadir=/var/lib/mysql >/dev/null 2>&1
$STD rc-update add mariadb default
$STD rc-service mariadb start
DB_NAME="romm"
DB_USER="romm"
DB_PASSWD=$(openssl rand -hex 16)
mariadb -u root <<EOF
CREATE DATABASE IF NOT EXISTS ${DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASSWD}';
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
EOF
msg_ok "Configured MariaDB"

msg_info "Building RAHasher"
git clone --recursive --branch 1.8.1 --depth 1 https://github.com/RetroAchievements/RALibretro.git /tmp/RALibretro
sed -i '22a #include <ctime>' /tmp/RALibretro/src/Util.h
sed -i '6a #include <unistd.h>' \
  /tmp/RALibretro/src/libchdr/deps/zlib-1.3.1/gzlib.c \
  /tmp/RALibretro/src/libchdr/deps/zlib-1.3.1/gzread.c \
  /tmp/RALibretro/src/libchdr/deps/zlib-1.3.1/gzwrite.c
make -C /tmp/RALibretro HAVE_CHD=1 -f /tmp/RALibretro/Makefile.RAHasher
install -m 0755 /tmp/RALibretro/bin64/RAHasher /usr/bin/RAHasher
rm -rf /tmp/RALibretro
msg_ok "Built RAHasher"

msg_info "Installing backend dependencies"
cd "$ROMM_HOME"
/usr/local/bin/uv python install 3.13
/usr/local/bin/uv venv --python 3.13
/usr/local/bin/uv sync --locked --no-cache
msg_ok "Installed backend dependencies"

msg_info "Building frontend"
cd "$ROMM_HOME/frontend"
$STD npm ci --ignore-scripts --no-audit --no-fund
$STD npm run build
msg_ok "Built frontend"

msg_info "Configuring RomM"
mkdir -p "$ROMM_BASE/library" "$ROMM_BASE/resources" "$ROMM_BASE/assets" "$ROMM_BASE/config" "$ROMM_BASE/tmp"
mkdir -p /redis-data
mkdir -p "$ROMM_ENV_DIR"
ROMM_AUTH_SECRET_KEY=$(openssl rand -hex 32)
cat <<EOF >"$ROMM_ENV_FILE"
ROMM_BASE_PATH=${ROMM_BASE}
ROMM_BASE_URL=http://0.0.0.0:8080
ROMM_PORT=8080
ROMM_TMP_PATH=${ROMM_BASE}/tmp
DEV_MODE=false
DEV_PORT=5000
DB_HOST=127.0.0.1
DB_PORT=3306
DB_NAME=${DB_NAME}
DB_USER=${DB_USER}
DB_PASSWD=${DB_PASSWD}
REDIS_HOST=
REDIS_PORT=6379
ROMM_AUTH_SECRET_KEY=${ROMM_AUTH_SECRET_KEY}
ENABLE_RESCAN_ON_FILESYSTEM_CHANGE=true
ENABLE_SCHEDULED_RESCAN=false
ENABLE_SCHEDULED_UPDATE_SWITCH_TITLEDB=false
ENABLE_SCHEDULED_UPDATE_LAUNCHBOX_METADATA=false
ENABLE_SCHEDULED_CONVERT_IMAGES_TO_WEBP=false
ENABLE_SCHEDULED_RETROACHIEVEMENTS_PROGRESS_SYNC=false
LOGLEVEL=INFO
EOF
ln -sfn "$ROMM_ENV_FILE" "$ROMM_HOME/.env"

cat <<EOF >"$ROMM_CRED_FILE"
RomM MariaDB Credentials
DB_NAME=${DB_NAME}
DB_USER=${DB_USER}
DB_PASSWD=${DB_PASSWD}
ROMM_AUTH_SECRET_KEY=${ROMM_AUTH_SECRET_KEY}
EOF
chmod 600 "$ROMM_CRED_FILE"
msg_ok "Configured RomM"

msg_info "Preparing frontend assets"
mkdir -p /var/www/html/assets/romm
cp -a "$ROMM_HOME/frontend/dist/." /var/www/html/
mkdir -p /var/www/html/assets
cp -a "$ROMM_HOME/frontend/assets/." /var/www/html/assets/
ln -sfn "$ROMM_BASE/resources" /var/www/html/assets/romm/resources
ln -sfn "$ROMM_BASE/assets" /var/www/html/assets/romm/assets
msg_ok "Prepared frontend assets"

msg_info "Configuring Nginx"
mkdir -p /var/log/nginx
mkdir -p /usr/lib/nginx/modules
mkdir -p "$ROMM_NGINX_JS_DIR"
cat <<'EOF' >"$ROMM_NGINX_JS_DIR/decode.js"
// Decode a Base64 encoded string received as a query parameter named 'value',
// and return the decoded value in the response body.
function decodeBase64(r) {
  var encodedValue = r.args.value;

  if (!encodedValue) {
    r.return(400, "Missing 'value' query parameter");
    return;
  }

  try {
    var decodedValue = atob(encodedValue);
    r.return(200, decodedValue);
  } catch (e) {
    r.return(400, "Invalid Base64 encoding");
  }
}

export default { decodeBase64 };
EOF

cat <<'EOF' >"$ROMM_NGINX_CONF"
load_module modules/ngx_http_js_module.so;
load_module modules/ngx_http_zip_module.so;

user romm;
worker_processes auto;
pid /tmp/nginx.pid;

events {
  worker_connections 768;
  multi_accept on;
}

http {
  client_body_temp_path /tmp/client_body 1 2;
  fastcgi_temp_path /tmp/fastcgi 1 2;
  proxy_temp_path /tmp/proxy;
  uwsgi_temp_path /tmp/uwsgi;
  scgi_temp_path /tmp/scgi;

  sendfile on;
  client_body_buffer_size 128k;
  client_max_body_size 0;
  client_header_buffer_size 1k;
  large_client_header_buffers 4 16k;
  send_timeout 600s;
  keepalive_timeout 600s;
  client_body_timeout 600s;
  tcp_nopush on;
  tcp_nodelay on;

  include /etc/nginx/mime.types;
  default_type application/octet-stream;

  ssl_protocols TLSv1 TLSv1.1 TLSv1.2 TLSv1.3;
  ssl_prefer_server_ciphers on;

  js_import /etc/nginx/js/decode.js;

  map $time_iso8601 $date {
    ~([^+]+)T $1;
  }
  map $time_iso8601 $time {
    ~T([0-9:]+)\+ $1;
  }

  map $http_user_agent $browser {
    default         "Unknown";
    "~Chrome/"      "Chrome";
    "~Firefox/"     "Firefox";
    "~Safari/"      "Safari";
    "~Edge/"        "Edge";
    "~Opera/"       "Opera";
  }

  map $http_user_agent $os {
    default         "Unknown";
    "~Windows NT"   "Windows";
    "~Macintosh"    "macOS";
    "~Linux"        "Linux";
    "~Android"      "Android";
    "~iPhone"       "iOS";
  }

  log_format romm_logs 'INFO:     [RomM][nginx][$date $time] '
    '$remote_addr | $http_x_forwarded_for | '
    '$request_method $request_uri $status | $body_bytes_sent | '
    '$browser $os | $request_time';

  access_log /var/log/nginx/romm-access.log romm_logs;
  error_log /var/log/nginx/romm-error.log;

  gzip on;
  gzip_proxied any;
  gzip_vary on;
  gzip_comp_level 6;
  gzip_buffers 16 8k;
  gzip_min_length 1024;
  gzip_http_version 1.1;
  gzip_types text/plain text/css application/json application/javascript text/xml application/xml application/xml+rss text/javascript;

  upstream wsgi_server {
    server unix:/tmp/gunicorn.sock;
  }

  include /etc/nginx/conf.d/*.conf;
}
EOF

cat <<EOF >"$ROMM_NGINX_SITE"
map \$http_x_forwarded_proto \$forwardscheme {
  default \$scheme;
  https https;
}

map \$request_uri \$coep_header {
  default        "";
  ~^/rom/.*/ejs$ "require-corp";
}
map \$request_uri \$coop_header {
  default        "";
  ~^/rom/.*/ejs$ "same-origin";
}

server {
  root /var/www/html;
  listen 8080;
  listen [::]:8080;
  server_name localhost;

  proxy_set_header Host \$http_host;
  proxy_set_header X-Real-IP \$remote_addr;
  proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
  proxy_set_header X-Forwarded-Proto \$forwardscheme;

  location / {
    try_files \$uri \$uri/ /index.html;
    proxy_redirect off;
    add_header Access-Control-Allow-Origin *;
    add_header Access-Control-Allow-Methods *;
    add_header Access-Control-Allow-Headers *;
    add_header Cross-Origin-Embedder-Policy \$coep_header;
    add_header Cross-Origin-Opener-Policy \$coop_header;
  }

  location /assets {
    try_files \$uri \$uri/ =404;
  }

  location /openapi.json {
    proxy_pass http://wsgi_server;
  }

  location /api {
    proxy_pass http://wsgi_server;
    proxy_request_buffering off;
    proxy_buffering off;
  }

  location ~ ^/(ws|netplay) {
    proxy_pass http://wsgi_server;
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
  }

  location /library/ {
    internal;
    alias "${ROMM_BASE}/library/";
  }

  location /decode {
    internal;
    js_content decode.decodeBase64;
  }
}
EOF
msg_ok "Configured Nginx"

msg_info "Building nginx mod_zip module"
if [[ ! -f /usr/lib/nginx/modules/ngx_http_zip_module.so ]]; then
  $STD apk add --no-cache --virtual .romm-nginx-build \
    git \
    gcc \
    make \
    libc-dev \
    pcre-dev \
    zlib-dev
  NGINX_VERSION=$(nginx -v 2>&1 | awk -F/ '{print $2}')
  git clone https://github.com/evanmiller/mod_zip.git /tmp/mod_zip
  git -C /tmp/mod_zip checkout a9f9afa441117831cc712a832c98408b3f0416f6
  git clone --branch "release-${NGINX_VERSION}" --depth 1 https://github.com/nginx/nginx.git /tmp/nginx-src
  cd /tmp/nginx-src
  ./auto/configure --with-compat --add-dynamic-module=/tmp/mod_zip/
  make -f ./objs/Makefile modules
  install -m 0644 ./objs/ngx_http_zip_module.so /usr/lib/nginx/modules/
  cd /
  rm -rf /tmp/mod_zip /tmp/nginx-src
  $STD apk del .romm-nginx-build
fi
msg_ok "nginx mod_zip ready"

msg_info "Installing RomM init script"
cat <<'EOF' >"$ROMM_GUNICORN_LOG"
[loggers]
keys=root,gunicorn,error

[handlers]
keys=console_gunicorn

[formatters]
keys=gunicorn_format

[logger_root]
level=WARNING
handlers=

[logger_gunicorn]
level=INFO
handlers=console_gunicorn
qualname=gunicorn
propagate=0

[logger_error]
level=ERROR
handlers=console_gunicorn
qualname=gunicorn.error
propagate=0

[handler_console_gunicorn]
class=StreamHandler
formatter=gunicorn_format
args=(sys.stdout,)

[formatter_gunicorn_format]
format=INFO:     [RomM][gunicorn][%(asctime)s] %(message)s
datefmt=%Y-%m-%d %H:%M:%S
EOF

cat <<'EOF' >"$ROMM_INIT_BIN"
#!/usr/bin/env bash
set -o errexit
set -o nounset
set -o pipefail
shopt -s inherit_errexit

ROMM_HOME="/opt/romm"
ROMM_ENV_FILE="/etc/romm/romm.env"
BACKEND_DIR="${ROMM_HOME}/backend"
VENV_DIR="${ROMM_HOME}/.venv"

if [[ -f "${ROMM_ENV_FILE}" ]]; then
  set -a
  . "${ROMM_ENV_FILE}"
  set +a
fi

export PATH="${VENV_DIR}/bin:${PATH}"
export PYTHONPATH="${BACKEND_DIR}:${PYTHONPATH-}"

LOGLEVEL="${LOGLEVEL:=INFO}"
ENABLE_RESCAN_ON_FILESYSTEM_CHANGE="${ENABLE_RESCAN_ON_FILESYSTEM_CHANGE:=false}"
ENABLE_SCHEDULED_RESCAN="${ENABLE_SCHEDULED_RESCAN:=false}"
ENABLE_SCHEDULED_UPDATE_LAUNCHBOX_METADATA="${ENABLE_SCHEDULED_UPDATE_LAUNCHBOX_METADATA:=false}"
ENABLE_SCHEDULED_UPDATE_SWITCH_TITLEDB="${ENABLE_SCHEDULED_UPDATE_SWITCH_TITLEDB:=false}"
REDIS_HOST="${REDIS_HOST:=}"

RED='\033[0;31m'
LIGHTMAGENTA='\033[0;95m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
RESET='\033[0;00m'

print_banner() {
  local version
  version=$(python3 -c "exec(open('${BACKEND_DIR}/__version__.py').read()); print(__version__)")
  info_log "               _____                 __  __ "
  info_log '              |  __ \               |  \/  |'
  info_log '              | |__) |___  _ __ ___ | \  / |'
  info_log "              |  _  // _ \\| '_ \` _ \\| |\\/| |"
  info_log '              | | \ \ (_) | | | | | | |  | |'
  info_log '              |_|  \_\___/|_| |_| |_|_|  |_|'
  info_log ""
  info_log "The beautiful, powerful, self-hosted Rom manager and player"
  info_log ""
  info_log "Version: ${version}"
  info_log ""
}

debug_log() {
  if [[ ${LOGLEVEL} == "DEBUG" ]]; then
    echo -e "${LIGHTMAGENTA}DEBUG:    ${BLUE}[RomM]${LIGHTMAGENTA}[init]${CYAN}[$(date +"%Y-%m-%d %T")]${RESET}" "${@}" || true
  fi
}

info_log() {
  echo -e "${GREEN}INFO:     ${BLUE}[RomM]${LIGHTMAGENTA}[init]${CYAN}[$(date +"%Y-%m-%d %T")]${RESET}" "${@}" || true
}

warn_log() {
  echo -e "${YELLOW}WARNING:  ${BLUE}[RomM]${LIGHTMAGENTA}[init]${CYAN}[$(date +"%Y-%m-%d %T")]${RESET}" "${@}" || true
}

error_log() {
  echo -e "${RED}ERROR:    ${BLUE}[RomM]${LIGHTMAGENTA}[init]${CYAN}[$(date +"%Y-%m-%d %T")]${RESET}" "${@}" || true
  exit 1
}

run_startup() {
  if ! PYTHONPATH="${BACKEND_DIR}:${PYTHONPATH-}" opentelemetry-instrument \
    --service_name "${OTEL_SERVICE_NAME_PREFIX-}startup" \
    python3 "${BACKEND_DIR}/startup.py"; then
    error_log "Startup script failed, exiting"
  fi
}

wait_for_gunicorn_socket() {
  debug_log "Waiting for gunicorn socket file..."
  local wait_seconds=${WEB_SERVER_GUNICORN_WAIT_SECONDS:=30}
  local retries=$((wait_seconds * 2))

  while [[ ! -S /tmp/gunicorn.sock && retries -gt 0 ]]; do
    sleep 0.5
    ((retries--))
  done

  if [[ -S /tmp/gunicorn.sock ]]; then
    debug_log "Gunicorn socket file found"
  else
    warn_log "Gunicorn socket file not found after waiting ${wait_seconds}s!"
  fi
}

start_bin_gunicorn() {
  rm /tmp/gunicorn.sock -f
  info_log "Starting backend"
  export PYTHONUNBUFFERED=1
  export PYTHONDONTWRITEBYTECODE=1

  opentelemetry-instrument \
    --service_name "${OTEL_SERVICE_NAME_PREFIX-}api" \
    gunicorn \
    --bind=0.0.0.0:"${DEV_PORT:-5000}" \
    --bind=unix:/tmp/gunicorn.sock \
    --pid=/tmp/gunicorn.pid \
    --forwarded-allow-ips="*" \
    --worker-class uvicorn_worker.UvicornWorker \
    --workers "${WEB_SERVER_CONCURRENCY:-1}" \
    --timeout "${WEB_SERVER_TIMEOUT:-300}" \
    --keep-alive "${WEB_SERVER_KEEPALIVE:-2}" \
    --max-requests "${WEB_SERVER_MAX_REQUESTS:-1000}" \
    --max-requests-jitter "${WEB_SERVER_MAX_REQUESTS_JITTER:-100}" \
    --worker-connections "${WEB_SERVER_WORKER_CONNECTIONS:-1000}" \
    --error-logfile - \
    --log-config /etc/romm/gunicorn-logging.conf \
    main:app &
}

start_bin_nginx() {
  wait_for_gunicorn_socket
  info_log "Starting nginx"
  nginx

  : "${ROMM_BASE_URL:=http://0.0.0.0:8080}"
  info_log "RomM is now available at ${ROMM_BASE_URL}"
}

start_bin_valkey-server() {
  info_log "Starting internal valkey"
  if [[ -f /usr/local/etc/valkey/valkey.conf ]]; then
    if [[ ${LOGLEVEL} == "DEBUG" ]]; then
      valkey-server /usr/local/etc/valkey/valkey.conf &
    else
      valkey-server /usr/local/etc/valkey/valkey.conf >/dev/null 2>&1 &
    fi
  else
    if [[ ${LOGLEVEL} == "DEBUG" ]]; then
      valkey-server --dir /redis-data &
    else
      valkey-server --dir /redis-data >/dev/null 2>&1 &
    fi
  fi

  VALKEY_PID=$!
  echo "${VALKEY_PID}" >/tmp/valkey-server.pid
}

start_bin_rq_scheduler() {
  info_log "Starting RQ scheduler"
  RQ_REDIS_HOST=${REDIS_HOST:-127.0.0.1} \
    RQ_REDIS_PORT=${REDIS_PORT:-6379} \
    RQ_REDIS_USERNAME=${REDIS_USERNAME:-""} \
    RQ_REDIS_PASSWORD=${REDIS_PASSWORD:-""} \
    RQ_REDIS_DB=${REDIS_DB:-0} \
    RQ_REDIS_SSL=${REDIS_SSL:-0} \
    rqscheduler \
    --path "${BACKEND_DIR}" \
    --pid /tmp/rq_scheduler.pid &
}

start_bin_rq_worker() {
  info_log "Starting RQ worker"
  local redis_url
  if [[ -n ${REDIS_PASSWORD-} ]]; then
    redis_url="redis${REDIS_SSL:+s}://${REDIS_USERNAME-}:${REDIS_PASSWORD}@${REDIS_HOST:-127.0.0.1}:${REDIS_PORT:-6379}/${REDIS_DB:-0}"
  elif [[ -n ${REDIS_USERNAME-} ]]; then
    redis_url="redis${REDIS_SSL:+s}://${REDIS_USERNAME}@${REDIS_HOST:-127.0.0.1}:${REDIS_PORT:-6379}/${REDIS_DB:-0}"
  else
    redis_url="redis${REDIS_SSL:+s}://${REDIS_HOST:-127.0.0.1}:${REDIS_PORT:-6379}/${REDIS_DB:-0}"
  fi

  PYTHONPATH="${BACKEND_DIR}:${PYTHONPATH-}" rq worker \
    --path "${BACKEND_DIR}" \
    --pid /tmp/rq_worker.pid \
    --url "${redis_url}" \
    --results-ttl "${TASK_RESULT_TTL:-86400}" \
    high default low &
}

start_bin_watcher() {
  info_log "Starting watcher"
  watchfiles \
    --target-type command \
    "opentelemetry-instrument --service_name '${OTEL_SERVICE_NAME_PREFIX-}watcher' python3 ${BACKEND_DIR}/watcher.py" \
    "${ROMM_BASE_PATH:-/romm}/library" &
  WATCHER_PID=$!
  echo "${WATCHER_PID}" >/tmp/watcher.pid
}

watchdog_process_pid() {
  PROCESS=$1
  if [[ -f "/tmp/${PROCESS}.pid" ]]; then
    PID=$(cat "/tmp/${PROCESS}.pid") || true
    if [[ ! -d "/proc/${PID}" ]]; then
      start_bin_"${PROCESS}"
    fi
  else
    start_bin_"${PROCESS}"
  fi
}

stop_process_pid() {
  PROCESS=$1
  if [[ -f "/tmp/${PROCESS}.pid" ]]; then
    PID=$(cat "/tmp/${PROCESS}.pid") || true
    if [[ -d "/proc/${PID}" ]]; then
      info_log "Stopping ${PROCESS}"
      kill "${PID}" || true
      while [[ -e "/proc/${PID}" ]]; do sleep 0.1; done
    fi
  fi
}

shutdown() {
  stop_process_pid rq_worker
  stop_process_pid rq_scheduler
  stop_process_pid watcher
  stop_process_pid nginx
  stop_process_pid gunicorn
  stop_process_pid valkey-server
}

mkdir -p /var/www/html/assets/romm
for subfolder in assets resources; do
  target="${ROMM_BASE_PATH:-/romm}/${subfolder}"
  link="/var/www/html/assets/romm/${subfolder}"
  if [[ -L "${link}" ]]; then
    current=$(readlink "${link}")
    if [[ "${current}" != "${target}" ]]; then
      rm "${link}"
      ln -s "${target}" "${link}"
    fi
  elif [[ ! -e "${link}" ]]; then
    ln -s "${target}" "${link}"
  fi
done

cd "${BACKEND_DIR}" || { error_log "${BACKEND_DIR} not found"; }

print_banner

exited=0
trap 'exited=1 && shutdown' SIGINT SIGTERM EXIT

rm /tmp/*.pid -f

if ! printenv | grep -q '^OTEL_'; then
  info_log "No OpenTelemetry environment variables found, disabling OpenTelemetry SDK"
  export OTEL_SDK_DISABLED=true
fi

if [[ -z ${ROMM_AUTH_SECRET_KEY:-} ]]; then
  ROMM_AUTH_SECRET_KEY=$(python3 -c "import secrets; print(secrets.token_hex(32))")
  info_log "ROMM_AUTH_SECRET_KEY not set, generating random secret key"
  export ROMM_AUTH_SECRET_KEY
fi

if [[ -z ${REDIS_HOST} ]]; then
  watchdog_process_pid valkey-server
else
  info_log "REDIS_HOST is set, not starting internal valkey-server"
fi

info_log "Running database migrations"
if alembic upgrade head; then
  info_log "Database migrations succeeded"
else
  error_log "Failed to run database migrations"
fi

run_startup

while ! ((exited)); do
  watchdog_process_pid gunicorn

  if [[ ${ENABLE_SCHEDULED_RESCAN} == "true" || ${ENABLE_SCHEDULED_UPDATE_SWITCH_TITLEDB} == "true" || ${ENABLE_SCHEDULED_UPDATE_LAUNCHBOX_METADATA} == "true" ]]; then
    watchdog_process_pid rq_scheduler
  fi

  watchdog_process_pid rq_worker

  if [[ ${ENABLE_RESCAN_ON_FILESYSTEM_CHANGE} == "true" ]]; then
    watchdog_process_pid watcher
  fi

  watchdog_process_pid nginx

  sleep 5
done
EOF
chmod +x "$ROMM_INIT_BIN"
msg_ok "Installed RomM init script"

msg_info "Creating RomM service"
cat <<'EOF' >/etc/init.d/romm
#!/sbin/openrc-run
description="RomM service"

command="/usr/local/bin/romm-init"
command_background="yes"
pidfile="/run/romm.pid"

depend() {
  need net
  need mariadb
}
EOF
chmod +x /etc/init.d/romm
msg_ok "Created RomM service"

msg_info "Setting ownership"
chown -R "$ROMM_USER":"$ROMM_GROUP" "$ROMM_HOME" "$ROMM_BASE" /var/www/html /redis-data || true
msg_ok "Set ownership"

msg_info "Cleaning up build dependencies"
$STD apk del .romm-build
msg_ok "Cleaned up build dependencies"

msg_info "Starting RomM"
$STD rc-update add romm default
$STD rc-service romm start
msg_ok "Started RomM"

motd_ssh
customize
