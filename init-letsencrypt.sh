#!/bin/bash

set -e

# 로그 함수
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# CLI 옵션 파싱을 위한 함수
parse_options() {
    while getopts "d:e:s:r:h" opt; do
        case $opt in
            d) IFS=',' read -ra domains <<< "$OPTARG" ;;
            e) email="$OPTARG" ;;
            s) staging="$OPTARG" ;;
            r) rsa_key_size="$OPTARG" ;;
            h) show_help ;;
            \?) log "잘못된 옵션: -$OPTARG" >&2; exit 1 ;;
        esac
    done
}

# 도움말 표시 함수
show_help() {
    echo "사용법: $0 [-d domain1,domain2,...] [-e email] [-s staging] [-r rsa_key_size]"
    echo "  -d: 쉼표로 구분된 도메인 목록 (필수)"
    echo "  -e: 이메일 주소 (선택, 하지만 권장)"
    echo "  -s: 스테이징 모드 (1: 활성화, 0: 비활성화, 기본값: 0)"
    echo "  -r: RSA 키 크기 (기본값: 4096)"
    echo "  -h: 이 도움말 표시"
    exit 0
}

# 기본값 설정
rsa_key_size=4096
data_path="./data/certbot"
staging=0

# CLI 옵션 파싱
parse_options "$@"

# 필수 옵션 확인
if [ ${#domains[@]} -eq 0 ]; then
    log "오류: 도메인을 지정해야 합니다." >&2
    show_help
fi

# Docker 네트워크 생성 함수
create_network() {
    if ! docker network inspect $1 >/dev/null 2>&1; then
        log "네트워크 $1 생성 중..."
        docker network create $1
    else
        log "네트워크 $1 이미 존재합니다."
    fi
}

# 필요한 Docker 네트워크 생성
create_network "nginx-network"

# Docker Compose 확인
if ! [ -x "$(command -v docker-compose)" ]; then
    log "오류: docker-compose가 설치되어 있지 않습니다." >&2
    exit 1
fi

if [ -d "$data_path" ]; then
    read -p "$domains에 대한 기존 데이터가 발견되었습니다. 계속 진행하여 기존 인증서를 교체하시겠습니까? (y/N) " decision
    if [ "$decision" != "Y" ] && [ "$decision" != "y" ]; then
        exit
    fi
fi

if [ ! -e "$data_path/conf/options-ssl-nginx.conf" ] || [ ! -e "$data_path/conf/ssl-dhparams.pem" ]; then
    echo "권장 TLS 매개변수 다운로드 중 ..."
    mkdir -p "$data_path/conf"
    curl -s https://raw.githubusercontent.com/certbot/certbot/master/certbot-nginx/certbot_nginx/_internal/tls_configs/options-ssl-nginx.conf > "$data_path/conf/options-ssl-nginx.conf"
    curl -s https://raw.githubusercontent.com/certbot/certbot/master/certbot/certbot/ssl-dhparams.pem > "$data_path/conf/ssl-dhparams.pem"
    echo
fi

echo "$domains에 대한 임시 인증서 생성 중 ..."
path="/etc/letsencrypt/live/$domains"
mkdir -p "$data_path/conf/live/$domains"
docker-compose run --rm --entrypoint "\
  openssl req -x509 -nodes -newkey rsa:$rsa_key_size -days 1\
    -keyout '$path/privkey.pem' \
    -out '$path/fullchain.pem' \
    -subj '/CN=localhost'" certbot
echo

echo "nginx 시작 중 ..."
docker-compose up --force-recreate -d nginx
echo

echo "$domains에 대한 임시 인증서 삭제 중 ..."
docker-compose run --rm --entrypoint "\
  rm -Rf /etc/letsencrypt/live/$domains && \
  rm -Rf /etc/letsencrypt/archive/$domains && \
  rm -Rf /etc/letsencrypt/renewal/$domains.conf" certbot
echo

# Nginx 설정 파일 생성 함수
create_nginx_conf() {
    local domain=$1
    local conf_file="./data/nginx/${domain}.conf"
    
    # 사용자에게 컨테이너 이름 물어보기
    read -p "${domain}에 대해 443 포트로 리다이렉트할 컨테이너 이름을 입력하세요: " container_name
    
    if [ ! -f "$conf_file" ]; then
        log "${domain}에 대한 Nginx 설정 파일 생성 중..."
        cat > "$conf_file" <<EOL
server {
    listen 80;
    server_name ${domain};
    server_tokens off;

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl;
    server_name ${domain};
    server_tokens off;

    ssl_certificate /etc/letsencrypt/live/${domain}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${domain}/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparam.pem;

    location / {
        proxy_pass  http://${container_name};
        proxy_set_header    Host                \$http_host;
        proxy_set_header    X-Real-IP           \$remote_addr;
        proxy_set_header    X-Forwarded-For     \$proxy_add_x_forwarded_for;
    }
}
EOL
        log "${domain}에 대한 Nginx 설정 파일이 생성되었습니다."
    else
        log "${domain}에 대한 Nginx 설정 파일이 이미 존재합니다."
    fi
}

# Let's Encrypt 인증서 요청 전에 Nginx 설정 파일 생성
for domain in "${domains[@]}"; do
    create_nginx_conf "$domain"
done

log "Let's Encrypt 인증서 요청 중 ($domains) ..."
# 도메인 인자 구성
domain_args=""
for domain in "${domains[@]}"; do
    domain_args="$domain_args -d $domain"
done

# 이메일 인자 선택
case "$email" in
    "") email_arg="--register-unsafely-without-email" ;;
    *) email_arg="--email $email" ;;
esac

# 필요한 경우 스테이징 모드 활성화
if [ $staging != "0" ]; then staging_arg="--staging"; fi

docker-compose run --rm --entrypoint "\
  certbot certonly --webroot -w /var/www/certbot \
    $staging_arg \
    $email_arg \
    $domain_args \
    --rsa-key-size $rsa_key_size \
    --agree-tos \
    --force-renewal" certbot
echo

log "nginx 재시작 중 ..."
docker-compose exec nginx nginx -s reload

log "인증서 발급 및 설정이 완료되었습니다."
log "필요한 Docker 네트워크가 생성되었습니다. 다른 애플리케이션에서 'nginx-network'를 사용할 수 있습니다."
log "각 도메인에 대한 Nginx 설정 파일이 data/nginx/ 폴더에 생성되었습니다. 필요에 따라 수정하세요."
