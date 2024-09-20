#!/bin/bash
set -e

# Constants
DATA_PATH="./data/certbot"
RSA_KEY_SIZE=4096
STAGING=0

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }

show_help() {
    echo "Usage: $0 [-d domain1,domain2,...] [-e email] [-s staging] [-r rsa_key_size]"
    echo "  -d: Comma-separated list of domains (required)"
    echo "  -e: Email address (optional, but recommended)"
    echo "  -s: Use staging server (1: yes, 0: no, default: 0)"
    echo "  -r: RSA key size (default: 4096)"
    echo "  -h: Show this help message"
    exit 0
}

parse_options() {
    while getopts "d:e:s:r:h" opt; do
        case $opt in
            d) IFS=',' read -ra DOMAINS <<< "$OPTARG" ;;
            e) EMAIL="$OPTARG" ;;
            s) STAGING="$OPTARG" ;;
            r) RSA_KEY_SIZE="$OPTARG" ;;
            h) show_help ;;
            \?) log "Invalid option: -$OPTARG" >&2; exit 1 ;;
        esac
    done
}

check_requirements() {
    if [ ${#DOMAINS[@]} -eq 0 ]; then
        log "Error: At least one domain is required." >&2
        show_help
    fi

    if ! [ -x "$(command -v docker-compose)" ]; then
        log "Error: docker-compose is not installed. Please refer to https://docs.docker.com/compose/install/#install-compose for installation instructions." >&2
        exit 1
    fi
}

setup_tls_parameters() {
    if [ ! -e "$DATA_PATH/conf/options-ssl-nginx.conf" ] || [ ! -e "$DATA_PATH/conf/ssl-dhparam.pem" ]; then
        log "Downloading recommended TLS parameters ..."
        mkdir -p "$DATA_PATH/conf"
        curl -s https://raw.githubusercontent.com/certbot/certbot/master/certbot-nginx/certbot_nginx/_internal/tls_configs/options-ssl-nginx.conf > "$DATA_PATH/conf/options-ssl-nginx.conf"
        curl -s https://raw.githubusercontent.com/certbot/certbot/master/certbot/certbot/ssl-dhparams.pem > "$DATA_PATH/conf/ssl-dhparam.pem"
    fi
}

create_temp_certificate() {
    local domain="$1"
    log "Creating temporary certificate for $domain ..."
    path="/etc/letsencrypt/live/$domain"
    mkdir -p "$DATA_PATH/conf/live/$domain"
    docker-compose run --rm --entrypoint "\
        openssl req -x509 -nodes -newkey rsa:$RSA_KEY_SIZE -days 1\
        -keyout '$path/privkey.pem' \
        -out '$path/fullchain.pem' \
        -subj '/CN=localhost'" certbot
}

delete_temp_certificate() {
    local domain="$1"
    log "Deleting temporary certificate for $domain ..."
    docker-compose run --rm --entrypoint "\
        rm -Rf /etc/letsencrypt/live/$domain && \
        rm -Rf /etc/letsencrypt/archive/$domain && \
        rm -Rf /etc/letsencrypt/renewal/$domain.conf" certbot
}

create_nginx_config() {
    local domain="$1"
    local conf_file="./data/nginx/${domain}.conf"
    
    if [ -f "$conf_file" ]; then
        read -p "Nginx config for $domain already exists. Overwrite? (y/N) " overwrite
        if [[ $overwrite != [yY] ]]; then
            log "Keeping existing Nginx config for $domain."
            return
        fi
    fi
    
    read -p "Is the target service ready? (y/N) " is_service_ready
    if [[ $is_service_ready == [yY] ]]; then
        read -p "Is the target service running in a container? (y/N) " is_container
        if [[ $is_container == [yY] ]]; then
            read -p "Enter container name for $domain: " target
            proxy_pass="\$upstream_app"
            set_upstream="set \$upstream_app ${target};"
        else
            read -p "Enter host IP for $domain: " host_ip
            read -p "Enter port for $domain: " host_port
            proxy_pass="${host_ip}:${host_port}"
            set_upstream=""
        fi
        location_block="
        # Use Docker's internal DNS
        resolver 127.0.0.11 valid=30s;

        location / {
            ${set_upstream}
            proxy_pass  http://${proxy_pass};
            proxy_set_header    Host                \$http_host;
            proxy_set_header    X-Real-IP           \$remote_addr;
            proxy_set_header    X-Forwarded-For     \$proxy_add_x_forwarded_for;

            # Display alternative HTML if the target service does not respond
            error_page 502 503 504 = @fallback;
        }

        location @fallback {
            return 200 '<!DOCTYPE html><html lang=\"en\"><head><meta charset=\"UTF-8\"><title>Service Under Preparation</title></head><body style=\"display: flex; flex-direction: column; justify-content: center; align-items: center; height: 100vh; font-family: Arial, sans-serif;\"><span style=\"font-size: 100px;\">🚧</span><h1>Service Under Preparation</h1></body></html>';
            add_header Content-Type text/html;
        }"
    else
        location_block="
        location / {
            return 200 '<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8"><title>SSL Certificate Installation Complete</title></head><body style="display: flex; flex-direction: column; justify-content: center; align-items: center; height: 100vh; font-family: Arial, sans-serif;"><span style="font-size: 100px;">🔒</span><h1>SSL Certificate Successfully Installed</h1><div style="font-size: 20px;"><p>✅ Nginx with Let\'s Encrypt SSL is now configured.</p><p>🌐 Your site is ready for HTTPS.</p><p>🚀 You can now proceed with your service deployment.</p></div></body></html>';
            add_header Content-Type text/html;
        }"
    fi
    
    log "Creating Nginx config for $domain ..."
    cat > "$conf_file" <<EOL
# Nginx configuration for ${domain}
# Created on $(date)

# HTTP server block - redirects all HTTP traffic to HTTPS
server {
    listen 80;
    server_name ${domain};
    server_tokens off;

    # Allow ACME challenge for Let's Encrypt certificate renewal
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    # Redirect all HTTP requests to HTTPS
    location / {
        return 301 https://\$host\$request_uri;
    }
}

# HTTPS server block
server {
    listen 443 ssl;
    server_name ${domain};
    server_tokens off;

    # SSL certificate configuration
    ssl_certificate /etc/letsencrypt/live/${domain}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${domain}/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparam.pem;

    ${location_block}
}
EOL
    log "Nginx config for $domain created with comments."
}

request_le_certificate() {
    log "Requesting Let's Encrypt certificate for ${DOMAINS[*]} ..."
    
    local domain_args=""
    for domain in "${DOMAINS[@]}"; do domain_args="$domain_args -d $domain"; done
    
    local email_arg="--register-unsafely-without-email"
    if [ -n "$EMAIL" ]; then email_arg="--email $EMAIL"; fi
    
    local staging_arg=""
    if [ $STAGING != "0" ]; then staging_arg="--staging"; fi

    docker-compose run --rm --entrypoint "\
        certbot certonly --webroot -w /var/www/certbot \
        $staging_arg \
        $email_arg \
        $domain_args \
        --rsa-key-size $RSA_KEY_SIZE \
        --agree-tos \
        --force-renewal" certbot
}

main() {
    parse_options "$@"
    check_requirements
    
    docker network create nginx-network 2>/dev/null || true
    
    setup_tls_parameters
    
    for domain in "${DOMAINS[@]}"; do
        create_temp_certificate "$domain"
    done
    
    log "Starting nginx ..."
    docker-compose up --force-recreate -d nginx
    
    for domain in "${DOMAINS[@]}"; do
        delete_temp_certificate "$domain"
        create_nginx_config "$domain"
    done
    
    request_le_certificate
    
    log "Restarting nginx ..."
    docker-compose exec nginx nginx -s reload
    
    log "Certificate issuance and setup completed."
    log "Nginx config files for each domain are in data/nginx/. Modify as needed."
}

main "$@"
