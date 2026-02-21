#!/bin/bash

# ==========================================
# WordPress 自動部署腳本
# ==========================================
# 功能：在 Incus 容器中自動部署 WordPress
# 作者：Super Z AI Assistant
# 版本：2.0.0
# ==========================================

set -o pipefail

# ==========================================
# 1. 環境載入與初始化
# ==========================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 載入參數配置
if [ -f "$SCRIPT_DIR/config.env" ]; then
    source "$SCRIPT_DIR/config.env"
else
    echo "❌ 找不到 config.env，請確認檔案存在於: $SCRIPT_DIR/config.env"
    exit 1
fi

# 載入文字配置
if [ -f "$SCRIPT_DIR/messages.env" ]; then
    source "$SCRIPT_DIR/messages.env"
else
    echo "❌ 找不到 messages.env"
    exit 1
fi

# 設定日誌目錄
LOG_DIR="${LOG_ROOT}"
mkdir -p "$LOG_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
MAIN_LOG="${LOG_DIR}/deploy_${TIMESTAMP}.log"
REPORT_FILE="${LOG_DIR}/report-${TIMESTAMP}.json"
CLOUD_INIT_FILE="${SCRIPT_DIR}/cloud-init-wp-${TIMESTAMP}.yaml"

# ==========================================
# 2. 函數定義
# ==========================================

# 日誌函數
log() {
    local level=$1
    local msg_template=$2
    shift 2
    local message
    message=$(printf "$msg_template" "$@")
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${level}] ${message}" | tee -a "$MAIN_LOG"
}

INFO() { log "INFO" "$1" "${@:2}"; }
WARN() { log "WARN" "$1" "${@:2}"; }
ERROR() { log "ERROR" "$1" "${@:2}"; }
DEBUG() { [[ "${DEBUG:-false}" == "true" ]] && log "DEBUG" "$1" "${@:2}" || true; }

# 生成隨機密碼
generate_password() {
    local length=${1:-16}
    # 使用 LC_ALL=C 確保 tr 能正確處理隨機位元組，並暫時忽略 pipe 造成的錯誤
    (LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$length") || true
}

# 錯誤陷阱
error_exit() {
    local LINE_NO=$1
    local ERROR_MSG=$2
    
    ERROR "腳本在第 ${LINE_NO} 行發生錯誤: ${ERROR_MSG}"
    
    # 輸出容器日誌 (如果容器存在)
    if incus list "$CONTAINER_NAME" --format csv 2>/dev/null | grep -q "$CONTAINER_NAME"; then
        INFO "$INFO_CONTAINER_LOGS"
        incus logs "$CONTAINER_NAME" --type runtime 2>/dev/null | tail -50 | tee -a "$MAIN_LOG"
    fi
    
    # 生成失敗報告
    cat <<EOF > "$REPORT_FILE"
{
    "timestamp": "$TIMESTAMP",
    "status": "failed",
    "error_line": $LINE_NO,
    "error_message": "$ERROR_MSG",
    "log": "$MAIN_LOG"
}
EOF
    
    ERROR "$MSG_ABORT"
    exit 1
}

trap 'error_exit $LINENO "命令執行失敗"' ERR

# 重試函數
retry() {
    local max_attempts=$1
    local delay=$2
    local cmd="${@:3}"
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        DEBUG "$DEBUG_EXEC" "$cmd"
        if eval "$cmd"; then
            return 0
        fi
        
        if [ $attempt -lt $max_attempts ]; then
            INFO "$INFO_RETRY" "$attempt" "$max_attempts"
            sleep "$delay"
        fi
        ((attempt++))
    done
    
    return 1
}

# 等待函數
wait_for() {
    local timeout=$1
    local check_cmd=$2
    local progress_msg=$3
    local elapsed=0
    
    while [ $elapsed -lt $timeout ]; do
        if eval "$check_cmd" >/dev/null 2>&1; then
            return 0
        fi
        printf "\r${progress_msg} (${elapsed}/${timeout} 秒)" >&2
        sleep 5
        ((elapsed += 5))
    done
    
    printf "\n" >&2
    return 1
}

# ==========================================
# 3. 預檢與準備
# ==========================================
INFO "$MSG_START"

# 檢查 Incus 是否已安裝
INFO "檢查 Incus 是否已安裝..."
if ! command -v incus &> /dev/null; then
    ERROR "$ERR_INCUS_NOT_INSTALLED"
    exit 1
fi

# --- Step 1: 預檢資源 ---
INFO "$STEP_PRECHECK" "PreCheck"
AVAIL_MEM=$(free -m | awk '/Mem:/ {print $7}')
AVAIL_DISK=$(df -BG / | awk 'NR==2 {print $4}' | sed 's/G//')

INFO "$STEP_PRECHECK_PASS" "$AVAIL_MEM" "$AVAIL_DISK"

if [ "$AVAIL_MEM" -lt 500 ] || [ "$AVAIL_DISK" -lt 10 ]; then
    ERROR "$ERR_RESOURCE_MIN"
    exit 1
fi

# 發出資源警告
if [ "$AVAIL_MEM" -lt 1000 ]; then
    WARN "$WARN_LOW_RESOURCE" "$AVAIL_MEM"
fi

# --- 自動生成密碼 (如果未設定) ---
if [ -z "$DB_PASS" ]; then
    DB_PASS=$(generate_password 32)
    INFO "$INFO_PASSWORD" "DB_PASS"
fi

if [ -z "$DB_ROOT_PASS" ]; then
    DB_ROOT_PASS=$(generate_password 32)
    INFO "$INFO_PASSWORD" "DB_ROOT_PASS"
fi

if [ -z "$WP_ADMIN_PASS" ]; then
    WP_ADMIN_PASS=$(generate_password 16)
    INFO "$INFO_PASSWORD" "WP_ADMIN_PASS"
fi

# --- Step 2: 獲取主機 IP ---
INFO "$STEP_DNS" "DNS" "${SUB_DOMAIN}.${DOMAIN}" "(獲取IP中...)"

HOST_IP=$(curl -s --connect-timeout 10 ifconfig.me 2>/dev/null)
if [ -z "$HOST_IP" ]; then
    # 備用方案
    HOST_IP=$(curl -s --connect-timeout 10 icanhazip.com 2>/dev/null)
fi

if [ -z "$HOST_IP" ]; then
    ERROR "$ERR_NETWORK"
    exit 1
fi

INFO "宿主機 Public IP: $HOST_IP"

# ==========================================
# 4. Cloudflare DNS 設定
# ==========================================
DNS_RECORD_NAME="${SUB_DOMAIN}.${DOMAIN}"

# 設定 Cloudflare API 認證標頭 (使用陣列處理多重 Header)
CF_HEADERS=(-H "Content-Type: application/json")
if [ -n "$CF_API_TOKEN" ]; then
    CF_HEADERS+=(-H "Authorization: Bearer $CF_API_TOKEN")
else
    CF_HEADERS+=(-H "X-Auth-Email: $CF_API_EMAIL")
    CF_HEADERS+=(-H "X-Auth-Key: $CF_API_KEY")
fi

INFO "查詢現有 DNS 記錄: $DNS_RECORD_NAME"
DEBUG "$DEBUG_API_REQ" "GET" "/zones/$CF_ZONE_ID/dns_records?name=$DNS_RECORD_NAME"

DNS_RECORD_RESPONSE=$(curl -s -X GET \
    "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records?name=$DNS_RECORD_NAME" \
    "${CF_HEADERS[@]}")

DEBUG "$DEBUG_API_RES" "$DNS_RECORD_RESPONSE"

# 檢查 API 回應
CF_SUCCESS=$(echo "$DNS_RECORD_RESPONSE" | jq -r '.success')
if [ "$CF_SUCCESS" != "true" ]; then
    CF_ERROR=$(echo "$DNS_RECORD_RESPONSE" | jq -r '.errors[0].message // "Unknown error"')
    ERROR "$ERR_DNS_API" "API" "$CF_ERROR"
    exit 1
fi

# 檢查記錄是否存在
DNS_RECORD_ID=$(echo "$DNS_RECORD_RESPONSE" | jq -r '.result[0].id // empty')
DNS_RECORD_IP=$(echo "$DNS_RECORD_RESPONSE" | jq -r '.result[0].content // empty')

if [ -n "$DNS_RECORD_ID" ]; then
    # 記錄已存在，更新 IP
    INFO "$STEP_DNS_EXISTS"
    
    if [ "$DNS_RECORD_IP" != "$HOST_IP" ]; then
        INFO "$STEP_DNS" "DNS" "$DNS_RECORD_NAME" "$HOST_IP (更新)"
        DEBUG "$DEBUG_API_REQ" "PUT" "/zones/$CF_ZONE_ID/dns_records/$DNS_RECORD_ID"
        
        UPDATE_RESPONSE=$(curl -s -X PUT \
            "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records/$DNS_RECORD_ID" \
            "${CF_HEADERS[@]}" \
            --data "{
                \"type\": \"A\",
                \"name\": \"$SUB_DOMAIN\",
                \"content\": \"$HOST_IP\",
                \"ttl\": $DNS_TTL,
                \"proxied\": $DNS_PROXY
            }")
        
        DEBUG "$DEBUG_API_RES" "$UPDATE_RESPONSE"
        
        UPDATE_SUCCESS=$(echo "$UPDATE_RESPONSE" | jq -r '.success')
        if [ "$UPDATE_SUCCESS" != "true" ]; then
            UPDATE_ERROR=$(echo "$UPDATE_RESPONSE" | jq -r '.errors[0].message // "Unknown error"')
            ERROR "$ERR_DNS_API" "UPDATE" "$UPDATE_ERROR"
            exit 1
        fi
        
        INFO "$STEP_DNS_UPDATED"
    else
        INFO "✅ DNS 記錄 IP 已正確設定，無需更新"
    fi
else
    # 建立新記錄
    INFO "$STEP_DNS" "DNS" "$DNS_RECORD_NAME" "$HOST_IP (新建)"
    DEBUG "$DEBUG_API_REQ" "POST" "/zones/$CF_ZONE_ID/dns_records"
    
    CREATE_RESPONSE=$(curl -s -X POST \
        "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records" \
        "${CF_HEADERS[@]}" \
        --data "{
            \"type\": \"A\",
            \"name\": \"$SUB_DOMAIN\",
            \"content\": \"$HOST_IP\",
            \"ttl\": $DNS_TTL,
            \"proxied\": $DNS_PROXY
        }")
    
    DEBUG "$DEBUG_API_RES" "$CREATE_RESPONSE"
    
    CREATE_SUCCESS=$(echo "$CREATE_RESPONSE" | jq -r '.success')
    if [ "$CREATE_SUCCESS" != "true" ]; then
        CREATE_ERROR=$(echo "$CREATE_RESPONSE" | jq -r '.errors[0].message // "Unknown error"')
        ERROR "$ERR_DNS_API" "CREATE" "$CREATE_ERROR"
        exit 1
    fi
    
    INFO "$STEP_DNS_CREATED"
fi

# 警告 Cloudflare Proxy 設定
if [ "$DNS_PROXY" == "true" ]; then
    WARN "$WARN_DNS_PROXY"
fi

# 等待 DNS 生效
INFO "$STEP_DNS_WAIT" "$TIMEOUT_DNS"
DNS_WAIT=0
while [ $DNS_WAIT -lt $TIMEOUT_DNS ]; do
    RESOLVED_IP=$(dig +short "$DNS_RECORD_NAME" @1.1.1.1 2>/dev/null | tail -1)
    
    if [ "$RESOLVED_IP" == "$HOST_IP" ]; then
        INFO "$STEP_DNS_VERIFIED" "$DNS_RECORD_NAME" "$RESOLVED_IP"
        break
    fi
    
    if [ "$DNS_PROXY" == "true" ]; then
        # Cloudflare Proxy 模式下，IP 可能不同
        if [ -n "$RESOLVED_IP" ]; then
            INFO "✅ DNS 已解析 (Proxy 模式): $DNS_RECORD_NAME -> $RESOLVED_IP"
            break
        fi
    fi
    
    printf "\r⏳ 等待 DNS 生效... (%d/%d 秒) 已解析: %s" "$DNS_WAIT" "$TIMEOUT_DNS" "${RESOLVED_IP:-N/A}"
    sleep 5
    ((DNS_WAIT += 5))
done
printf "\n"

if [ "$DNS_WAIT" -ge "$TIMEOUT_DNS" ]; then
    if [ "$DNS_PROXY" != "true" ]; then
        ERROR "$ERR_DNS_TIMEOUT" "$TIMEOUT_DNS"
        exit 1
    fi
fi

# ==========================================
# 5. 檢查並清理舊容器
# ==========================================
CONTAINER_NAME="wp-${SUB_DOMAIN}"

if incus list "$CONTAINER_NAME" --format csv 2>/dev/null | grep -q "$CONTAINER_NAME"; then
    WARN "$WARN_CONTAINER_EXISTS" "$CONTAINER_NAME"
    INFO "正在停止並刪除舊容器..."
    incus stop "$CONTAINER_NAME" --force 2>/dev/null || true
    incus delete "$CONTAINER_NAME" --force 2>/dev/null || true
    sleep 2
fi

# ==========================================
# 6. 生成 Cloud-init YAML
# ==========================================
INFO "$STEP_LAUNCH" "Launch" "$PHP_VER" "$MARIADB_VER"

cat <<EOF > "$CLOUD_INIT_FILE"
#cloud-config
# WordPress 自動部署 Cloud-init 設定
# 生成時間: $TIMESTAMP

# ==========================================
# 系統更新與基礎套件
# ==========================================
package_update: true
package_upgrade: true

packages:
  - curl
  - wget
  - gnupg2
  - ca-certificates
  - lsb-release
  - software-properties-common
  - unzip
  - rsync
  - jq
  - git

# ==========================================
# 系統設定
# ==========================================
timezone: Asia/Taipei
locale: zh_TW.UTF-8

# ==========================================
# 檔案寫入
# ==========================================
write_files:
  # Nginx 主設定檔
  - path: /etc/nginx/sites-available/wordpress
    content: |
      server {
          listen 80;
          listen [::]:80;
          server_name ${SUB_DOMAIN}.${DOMAIN};
          root /var/www/wordpress;
          index index.php index.html;

          client_max_body_size ${NGINX_CLIENT_MAX_BODY_SIZE};

          # WordPress SEO URL
          location / {
              try_files \$uri \$uri/ /index.php?\$args;
          }

          # PHP 處理
          location ~ \.php$ {
              fastcgi_pass unix:/run/php/php${PHP_VER}-fpm.sock;
              fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
              include fastcgi_params;
              fastcgi_read_timeout 300;
          }

          # 靜態檔案快取
          location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2)$ {
              expires max;
              log_not_found off;
          }

          # 安全性設定
          location ~ /\. {
              deny all;
          }
          location ~ /wp-config.php {
              deny all;
          }
      }
    permissions: '0644'

  # PHP 設定檔
  - path: /etc/php/${PHP_VER}/fpm/conf.d/99-wordpress.ini
    content: |
      ; WordPress PHP 設定
      memory_limit = 256M
      upload_max_filesize = ${NGINX_CLIENT_MAX_BODY_SIZE}
      post_max_size = ${NGINX_CLIENT_MAX_BODY_SIZE}
      max_execution_time = 300
      max_input_vars = 3000
      display_errors = ${WP_DEBUG}
      log_errors = On
      error_log = /var/log/php${PHP_VER}-fpm/error.log
    permissions: '0644'

  # WP-CLI 安裝腳本
  - path: /opt/install-wp.sh
    content: |
      #!/bin/bash
      set -e
      
      echo "=== 安裝 WP-CLI ==="
      curl -sSL https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar -o /usr/local/bin/wp
      chmod +x /usr/local/bin/wp
      
      echo "=== 下載 WordPress ==="
      mkdir -p /var/www/wordpress
      cd /var/www/wordpress
      
      /usr/local/bin/wp core download --version=${WORDPRESS_VER} --locale=${WP_LANG} --allow-root
      
      echo "=== 建立 wp-config.php ==="
      /usr/local/bin/wp config create \\
          --dbname=${DB_NAME} \\
          --dbuser=${DB_USER} \\
          --dbpass='${DB_PASS}' \\
          --dbhost=localhost \\
          --dbprefix=${DB_PREFIX} \\
          --allow-root
      
      # 加入安全性設定
      /usr/local/bin/wp config set FS_METHOD direct --allow-root
      /usr/local/bin/wp config set WP_MEMORY_LIMIT '256M' --allow-root
      /usr/local/bin/wp config set WP_MAX_MEMORY_LIMIT '512M' --allow-root
      
      echo "=== 安裝 WordPress ==="
      /usr/local/bin/wp core install \\
          --url=https://${SUB_DOMAIN}.${DOMAIN} \\
          --title="${WP_TITLE}" \\
          --admin_user=${WP_ADMIN_USER} \\
          --admin_password='${WP_ADMIN_PASS}' \\
          --admin_email=${WP_ADMIN_EMAIL} \\
          --allow-root
      
      echo "=== 安裝外掛 ==="
      if [ -n "${WP_PLUGINS}" ]; then
          IFS=',' read -ra PLUGINS <<< "${WP_PLUGINS}"
          for plugin in "\${PLUGINS[@]}"; do
              /usr/local/bin/wp plugin install "\$plugin" --activate --allow-root || true
          done
      fi
      
      echo "=== 安裝佈景主題 ==="
      if [ -n "${WP_THEME}" ]; then
          /usr/local/bin/wp theme install ${WP_THEME} --activate --allow-root || true
      fi
      
      echo "=== 設定權限 ==="
      chown -R www-data:www-data /var/www/wordpress
      find /var/www/wordpress -type d -exec chmod 755 {} \;
      find /var/www/wordpress -type f -exec chmod 644 {} \;
      chmod 600 /var/www/wordpress/wp-config.php
      
      echo "=== WordPress 安裝完成 ==="
    permissions: '0755'

# ==========================================
# 執行命令
# ==========================================
runcmd:
  # --- 新增 PHP 套件庫 ---
  - add-apt-repository -y ppa:ondrej/php

  # --- 新增 MariaDB 套件庫 ---
  - curl -LsS https://r.mariadb.com/downloads/mariadb_repo_setup | sudo bash -s -- --mariadb-server-version="mariadb-${MARIADB_VER}"

  # --- 安裝 Nginx, PHP, MariaDB ---
  - apt-get update
  - apt-get install -y nginx nginx-common
  - apt-get install -y php${PHP_VER} php${PHP_VER}-fpm php${PHP_VER}-mysql php${PHP_VER}-curl php${PHP_VER}-gd php${PHP_VER}-intl php${PHP_VER}-mbstring php${PHP_VER}-xml php${PHP_VER}-zip php${PHP_VER}-imagick php${PHP_VER}-bcmath
  - apt-get install -y mariadb-server mariadb-client

  # --- 設定 MariaDB ---
  - systemctl enable mariadb
  - systemctl start mariadb
  - |
    mysql -u root <<EOSQL
    SET SESSION sql_for_binlog='NO_AUTO_CREATE_USER,NO_ENGINE_SUBSTITUTION';
    CREATE DATABASE IF NOT EXISTS ${DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
    CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
    GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';
    FLUSH PRIVILEGES;
    EOSQL
  - mysql -u root -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_ROOT_PASS}';" || true

  # --- 設定 Nginx ---
  - ln -sf /etc/nginx/sites-available/wordpress /etc/nginx/sites-enabled/wordpress
  - rm -f /etc/nginx/sites-enabled/default
  - systemctl enable nginx
  - systemctl start nginx

  # --- 設定 PHP-FPM ---
  - systemctl enable php${PHP_VER}-fpm
  - systemctl start php${PHP_VER}-fpm

  # --- 安裝 WordPress ---
  - /opt/install-wp.sh

  # --- 安裝 Certbot ---
  - apt-get install -y certbot python3-certbot-nginx

  # --- 建立 SSL 申請腳本 ---
  - |
    cat > /opt/request-ssl.sh << 'SSLEOF'
    #!/bin/bash
    STAGING=""
    if [ "${SSL_STAGING}" = "true" ]; then
        STAGING="--test-cert"
    fi
    
    certbot --nginx \\
        --non-interactive \\
        --agree-tos \\
        --email ${SSL_EMAIL} \\
        --domains ${SUB_DOMAIN}.${DOMAIN} \\
        \$STAGING \\
        --redirect
    
    # 設定自動更新
    systemctl enable certbot.timer
    systemctl start certbot.timer
    SSLEOF
    chmod +x /opt/request-ssl.sh

# ==========================================
# 最終訊息
# ==========================================
final_message: |
  ╔══════════════════════════════════════════════════════════╗
  ║         WordPress 容器設定完成！                         ║
  ╠══════════════════════════════════════════════════════════╣
  ║  網址: https://${SUB_DOMAIN}.${DOMAIN}
  ║  管理員: ${WP_ADMIN_USER}
  ║  請執行 /opt/request-ssl.sh 申請 SSL 憑證               ║
  ╚══════════════════════════════════════════════════════════╝
EOF

DEBUG "Cloud-init 檔案已生成: $CLOUD_INIT_FILE"

# ==========================================
# 7. 啟動 Incus 容器
# ==========================================
INFO "$STEP_LAUNCH" "Launch" "$PHP_VER" "$MARIADB_VER"

incus launch "$INCUS_IMAGE" "$CONTAINER_NAME" \
    -c limits.cpu="$LIMIT_CPU" \
    -c limits.memory="$LIMIT_MEM" \
    -d root,size="$LIMIT_DISK" \
    --config=user.user-data="$(cat "$CLOUD_INIT_FILE")"

INFO "$STEP_LAUNCH_DONE" "$CONTAINER_NAME"

# ==========================================
# 8. 等待容器 IP
# ==========================================
INFO "$STEP_WAIT_IP" "WaitIP"

CONTAINER_IP=""
IP_WAIT=0

while [ $IP_WAIT -lt $TIMEOUT_IP ]; do
    CONTAINER_IP=$(incus list "$CONTAINER_NAME" --format csv -c 4 2>/dev/null | grep -oP '\d+\.\d+\.\d+\.\d+' | head -1)
    
    if [ -n "$CONTAINER_IP" ]; then
        INFO "$STEP_IP_ASSIGNED" "$CONTAINER_IP"
        break
    fi
    
    printf "\r⏳ 等待容器 IP 分配... (%d/%d 秒)" "$IP_WAIT" "$TIMEOUT_IP"
    sleep 5
    ((IP_WAIT += 5))
done
printf "\n"

if [ -z "$CONTAINER_IP" ]; then
    ERROR "$ERR_IP_TIMEOUT" "$TIMEOUT_IP"
    exit 1
fi

# ==========================================
# 9. 等待 Cloud-init 完成
# ==========================================
INFO "$STEP_CLOUD_INIT" "CloudInit"

CLOUD_INIT_WAIT=0

while [ $CLOUD_INIT_WAIT -lt $TIMEOUT_CLOUD_INIT ]; do
    STATUS=$(incus exec "$CONTAINER_NAME" -- cloud-init status 2>/dev/null || echo "pending")
    
    printf "\r⏳ Cloud-init 狀態: %s (%d/%d 秒)" "$STATUS" "$CLOUD_INIT_WAIT" "$TIMEOUT_CLOUD_INIT"
    
    case "$STATUS" in
        "done")
            printf "\n"
            INFO "$STEP_CLOUD_INIT_DONE"
            break
            ;;
        "error")
            printf "\n"
            ERROR "$ERR_CLOUD_INIT_FAIL" "/var/log/cloud-init-output.log"
            incus exec "$CONTAINER_NAME" -- cat /var/log/cloud-init-output.log | tail -50 | tee -a "$MAIN_LOG"
            exit 1
            ;;
    esac
    
    sleep 10
    ((CLOUD_INIT_WAIT += 10))
done
printf "\n"

if [ $CLOUD_INIT_WAIT -ge $TIMEOUT_CLOUD_INIT ]; then
    ERROR "$ERR_CLOUD_INIT_TIMEOUT" "$TIMEOUT_CLOUD_INIT"
    exit 1
fi

# ==========================================
# 10. 申請 SSL 憑證
# ==========================================
INFO "$STEP_SSL" "SSL"

if [ "$SSL_STAGING" == "true" ]; then
    WARN "$WARN_SSL_STAGING"
fi

# 執行 SSL 申請腳本
SSL_OUTPUT=$(incus exec "$CONTAINER_NAME" -- /opt/request-ssl.sh 2>&1)
DEBUG "SSL 申請輸出: $SSL_OUTPUT"

# 檢查 SSL 是否成功
SSL_CHECK=$(incus exec "$CONTAINER_NAME" -- test -f /etc/letsencrypt/live/${SUB_DOMAIN}.${DOMAIN}/fullchain.pem && echo "success" || echo "failed")

if [ "$SSL_CHECK" == "success" ]; then
    INFO "$STEP_SSL_DONE"
else
    ERROR "$ERR_SSL_FAIL" "$SSL_OUTPUT"
    # 不退出，允許手動處理
    WARN "SSL 申請失敗，WordPress 仍可透過 HTTP 存取"
fi

# ==========================================
# 11. 驗證 WordPress
# ==========================================
INFO "$STEP_VERIFY" "Verify"

FINAL_URL="https://${SUB_DOMAIN}.${DOMAIN}"

# 等待服務完全啟動
sleep 10

# 測試 HTTP 回應
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -k "$FINAL_URL" 2>/dev/null || echo "000")

if [ "$HTTP_STATUS" == "200" ] || [ "$HTTP_STATUS" == "301" ] || [ "$HTTP_STATUS" == "302" ]; then
    INFO "$STEP_VERIFY_DONE"
else
    # 嘗試 HTTP
    HTTP_URL="http://${SUB_DOMAIN}.${DOMAIN}"
    HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$HTTP_URL" 2>/dev/null || echo "000")
    
    if [ "$HTTP_STATUS" == "200" ]; then
        INFO "✅ WordPress 已就緒 (HTTP): $HTTP_URL"
        FINAL_URL="$HTTP_URL"
    else
        ERROR "$ERR_WP_VERIFY" "$HTTP_STATUS"
        # 繼續執行，生成報告
    fi
fi

# ==========================================
# 12. 生成部署報告
# ==========================================
INFO "$MSG_LOG_SAVED" "$REPORT_FILE"

cat <<EOF > "$REPORT_FILE"
{
    "timestamp": "$TIMESTAMP",
    "status": "success",
    "domain": {
        "url": "$FINAL_URL",
        "subdomain": "$SUB_DOMAIN",
        "domain": "$DOMAIN"
    },
    "container": {
        "name": "$CONTAINER_NAME",
        "ip": "$CONTAINER_IP",
        "image": "$INCUS_IMAGE",
        "limits": {
            "cpu": "$LIMIT_CPU",
            "memory": "$LIMIT_MEM",
            "disk": "$LIMIT_DISK"
        }
    },
    "stack": {
        "php": "$PHP_VER",
        "mariadb": "$MARIADB_VER",
        "wordpress": "$WORDPRESS_VER"
    },
    "database": {
        "name": "$DB_NAME",
        "user": "$DB_USER"
    },
    "wordpress": {
        "admin_user": "$WP_ADMIN_USER",
        "admin_email": "$WP_ADMIN_EMAIL",
        "language": "$WP_LANG"
    },
    "ssl": {
        "enabled": $([ "$SSL_CHECK" == "success" ] && echo "true" || echo "false"),
        "email": "$SSL_EMAIL"
    },
    "dns": {
        "record": "$DNS_RECORD_NAME",
        "ip": "$HOST_IP",
        "proxy": $DNS_PROXY
    },
    "files": {
        "log": "$MAIN_LOG",
        "cloud_init": "$CLOUD_INIT_FILE"
    }
}
EOF

# ==========================================
# 13. 完成訊息
# ==========================================
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "                    🎉 WordPress 部署完成！                    "
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "  🌐 網站位址:  $FINAL_URL"
echo "  🔑 管理後台:  $FINAL_URL/wp-admin/"
echo "  👤 管理員:    $WP_ADMIN_USER"
echo ""
echo "  📋 容器名稱:  $CONTAINER_NAME"
echo "  🌍 容器 IP:   $CONTAINER_IP"
echo ""
echo "  📄 部署報告:  $REPORT_FILE"
echo "  📝 完整日誌:  $MAIN_LOG"
echo ""
echo "  提示："
echo "    - 進入容器: incus shell $CONTAINER_NAME"
echo "    - 查看日誌: incus logs $CONTAINER_NAME"
echo "    - 重啟容器: incus restart $CONTAINER_NAME"
echo ""
echo "═══════════════════════════════════════════════════════════════"

INFO "$MSG_SUCCESS" "$FINAL_URL"
INFO "$MSG_LOG_SAVED" "$REPORT_FILE"

exit 0
