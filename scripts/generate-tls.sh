#!/bin/bash
# ============================================================
# TLS Certificate Generation Script
# Generates or validates TLS certificates for Postfix/Dovecot
# ============================================================

set -e

LOG_PREFIX="[tls-gen]"

log() {
    echo "$LOG_PREFIX $1"
}

error() {
    echo "$LOG_PREFIX ERROR: $1" >&2
    exit 1
}

# Usage: generate-tls.sh <type> [domain] [cert_dir] [cert_path] [key_path]
# Types: self-signed, existing, letsencrypt
CERT_TYPE="${1:-self-signed}"
DOMAIN="${2:-$(hostname)}"
CERT_DIR="${3:-/data/certs}"
CERT_SRC="${4:-}"
KEY_SRC="${5:-}"

mkdir -p "$CERT_DIR"

case "$CERT_TYPE" in
    self-signed)
        log "Generating self-signed TLS certificate for ${DOMAIN}..."
        
        # Generate CA private key and certificate
        openssl genrsa -out "${CERT_DIR}/ca.key" 4096 2>/dev/null
        openssl req -x509 -new -nodes \
            -key "${CERT_DIR}/ca.key" \
            -sha256 -days 3650 \
            -out "${CERT_DIR}/ca.crt" \
            -subj "/C=US/ST=Local/L=Local/O=SMTP-Relay-CA/CN=SMTP-Relay-CA" 2>/dev/null
        
        # Generate server private key
        openssl genrsa -out "${CERT_DIR}/mail.key" 2048 2>/dev/null
        
        # Generate CSR
        openssl req -new \
            -key "${CERT_DIR}/mail.key" \
            -out "${CERT_DIR}/mail.csr" \
            -subj "/C=US/ST=Local/L=Local/O=SMTP-Relay/CN=${DOMAIN}" 2>/dev/null
        
        # Create SAN extension file
        cat > "${CERT_DIR}/san.cnf" << EOF
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[req_distinguished_name]
C = US
ST = Local
L = Local
O = SMTP-Relay
CN = ${DOMAIN}

[v3_req]
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
subjectAltName = @alt_names

[alt_names]
DNS.1 = ${DOMAIN}
DNS.2 = *.${DOMAIN}
DNS.3 = localhost
IP.1 = 127.0.0.1
EOF
        
        # Sign the certificate with CA
        openssl x509 -req \
            -in "${CERT_DIR}/mail.csr" \
            -CA "${CERT_DIR}/ca.crt" \
            -CAkey "${CERT_DIR}/ca.key" \
            -CAcreateserial \
            -out "${CERT_DIR}/mail.crt" \
            -days 3650 -sha256 \
            -extensions v3_req \
            -extfile "${CERT_DIR}/san.cnf" 2>/dev/null
        
        # Clean up CSR and temp files
        rm -f "${CERT_DIR}/mail.csr" "${CERT_DIR}/san.cnf" "${CERT_DIR}/ca.srl"
        
        # Set permissions
        chmod 600 "${CERT_DIR}/mail.key" "${CERT_DIR}/ca.key"
        chmod 644 "${CERT_DIR}/mail.crt" "${CERT_DIR}/ca.crt"
        
        log "Self-signed certificate generated successfully."
        log "  Certificate: ${CERT_DIR}/mail.crt"
        log "  Private key: ${CERT_DIR}/mail.key"
        log "  CA cert: ${CERT_DIR}/ca.crt"
        
        echo ""
        echo "Self-signed TLS certificate created."
        echo "  cert_file=${CERT_DIR}/mail.crt"
        echo "  key_file=${CERT_DIR}/mail.key"
        ;;
        
    existing)
        log "Configuring existing TLS certificate..."
        
        if [ -z "$CERT_SRC" ] || [ -z "$KEY_SRC" ]; then
            error "Existing certificate requires --cert-path and --key-path"
        fi
        
        if [ ! -f "$CERT_SRC" ]; then
            error "Certificate file not found: $CERT_SRC"
        fi
        
        if [ ! -f "$KEY_SRC" ]; then
            error "Key file not found: $KEY_SRC"
        fi
        
        # Copy to persistent storage
        cp "$CERT_SRC" "${CERT_DIR}/mail.crt"
        cp "$KEY_SRC" "${CERT_DIR}/mail.key"
        
        # Set permissions
        chmod 600 "${CERT_DIR}/mail.key"
        chmod 644 "${CERT_DIR}/mail.crt"
        
        log "Existing certificate configured."
        log "  Certificate: ${CERT_DIR}/mail.crt"
        log "  Private key: ${CERT_DIR}/mail.key"
        
        echo ""
        echo "Existing TLS certificate configured."
        echo "  cert_file=${CERT_DIR}/mail.crt"
        echo "  key_file=${CERT_DIR}/mail.key"
        ;;
        
    letsencrypt)
        log "Configuring Let's Encrypt TLS certificate..."
        
        LE_CERT_PATH="/etc/letsencrypt/live/${DOMAIN}"
        
        # Check common Let's Encrypt paths
        CERT_FOUND=0
        for path in "$LE_CERT_PATH" "/etc/letsencrypt/live/mail.${DOMAIN}"; do
            if [ -f "${path}/fullchain.pem" ] && [ -f "${path}/privkey.pem" ]; then
                cp "${path}/fullchain.pem" "${CERT_DIR}/mail.crt"
                cp "${path}/privkey.pem" "${CERT_DIR}/mail.key"
                CERT_FOUND=1
                break
            fi
        done
        
        if [ "$CERT_FOUND" -eq 0 ]; then
            # Check if running inside docker and LE certs are mounted
            if [ -n "$CERT_SRC" ] && [ -n "$KEY_SRC" ]; then
                if [ -f "$CERT_SRC" ] && [ -f "$KEY_SRC" ]; then
                    cp "$CERT_SRC" "${CERT_DIR}/mail.crt"
                    cp "$KEY_SRC" "${CERT_DIR}/mail.key"
                    CERT_FOUND=1
                fi
            fi
        fi
        
        if [ "$CERT_FOUND" -eq 0 ]; then
            error "Let's Encrypt certificates not found for ${DOMAIN}. Checked: ${LE_CERT_PATH}"
        fi
        
        # Set permissions
        chmod 600 "${CERT_DIR}/mail.key"
        chmod 644 "${CERT_DIR}/mail.crt"
        
        log "Let's Encrypt certificate configured."
        log "  Certificate: ${CERT_DIR}/mail.crt"
        log "  Private key: ${CERT_DIR}/mail.key"
        
        echo ""
        echo "Let's Encrypt TLS certificate configured."
        echo "  cert_file=${CERT_DIR}/mail.crt"
        echo "  key_file=${CERT_DIR}/mail.key"
        ;;
        
    *)
        error "Unknown certificate type: ${CERT_TYPE}. Use: self-signed, existing, letsencrypt"
        ;;
esac

# Verify certificate and key match
if [ -f "${CERT_DIR}/mail.crt" ] && [ -f "${CERT_DIR}/mail.key" ]; then
    CERT_MOD=$(openssl x509 -noout -modulus -in "${CERT_DIR}/mail.crt" 2>/dev/null | openssl md5)
    KEY_MOD=$(openssl rsa -noout -modulus -in "${CERT_DIR}/mail.key" 2>/dev/null | openssl md5)
    
    if [ "$CERT_MOD" = "$KEY_MOD" ]; then
        log "Certificate and key match verified."
    else
        log "WARNING: Certificate and key modulus do not match!"
    fi
fi

echo ""
echo "TLS configuration complete."