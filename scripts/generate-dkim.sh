#!/bin/bash
# ============================================================
# DKIM Key Generation Script
# Generates DKIM key pair and displays DNS record
# ============================================================

set -e

LOG_PREFIX="[dkim-gen]"

log() {
    echo "$LOG_PREFIX $1"
}

error() {
    echo "$LOG_PREFIX ERROR: $1" >&2
    exit 1
}

# Usage: generate-dkim.sh <domain> <selector> [key_size]
DOMAIN="${1:-}"
SELECTOR="${2:-}"
KEY_SIZE="${3:-2048}"

if [ -z "$DOMAIN" ] || [ -z "$SELECTOR" ]; then
    error "Usage: $0 <domain> <selector> [key_size]"
fi

# Validate key size
if [ "$KEY_SIZE" -lt 1024 ] 2>/dev/null; then
    error "Key size must be at least 1024 bits"
fi

# Directories
DKIM_DATA_DIR="${DKIM_DATA_DIR:-/data/dkim}"
KEY_DIR="${DKIM_DATA_DIR}/${DOMAIN}"

log "Generating DKIM key pair for ${SELECTOR}._domainkey.${DOMAIN}"

# Create key directory
mkdir -p "$KEY_DIR"

# Generate DKIM key pair using opendkim-genkey
if command -v opendkim-genkey > /dev/null 2>&1; then
    opendkim-genkey \
        -b "$KEY_SIZE" \
        -d "$DOMAIN" \
        -D "$KEY_DIR" \
        -s "$SELECTOR" \
        -v \
        2>/dev/null || true
    
    # Rename files if needed
    if [ -f "${KEY_DIR}/${SELECTOR}.private" ]; then
        log "Private key: ${KEY_DIR}/${SELECTOR}.private"
    fi
    
    if [ -f "${KEY_DIR}/${SELECTOR}.txt" ]; then
        log "DNS record file: ${KEY_DIR}/${SELECTOR}.txt"
    fi
else
    # Fallback: generate with openssl if opendkim-genkey is not available
    log "opendkim-genkey not found, using openssl fallback..."
    
    # Generate RSA private key
    openssl genrsa -out "${KEY_DIR}/${SELECTOR}.private" "$KEY_SIZE" 2>/dev/null
    
    # Extract public key
    openssl rsa -in "${KEY_DIR}/${SELECTOR}.private" \
        -pubout -out "${KEY_DIR}/${SELECTOR}.public" 2>/dev/null
    
    # Format as DNS TXT record
    PUBLIC_KEY=$(cat "${KEY_DIR}/${SELECTOR}.public" | \
        sed -n '/-----BEGIN PUBLIC KEY-----/,/-----END PUBLIC KEY-----/p' | \
        grep -v "PUBLIC KEY" | tr -d '\n' | fold -w 200)
    
    cat > "${KEY_DIR}/${SELECTOR}.txt" << EOF
${SELECTOR}._domainkey	IN	TXT	"v=DKIM1; k=rsa; p=${PUBLIC_KEY}"
EOF
    
    log "Private key: ${KEY_DIR}/${SELECTOR}.private"
    log "Public key: ${KEY_DIR}/${SELECTOR}.public"
    log "DNS record file: ${KEY_DIR}/${SELECTOR}.txt"
fi

# Set permissions
chmod 600 "${KEY_DIR}/${SELECTOR}.private"
chmod 644 "${KEY_DIR}/${SELECTOR}.txt" 2>/dev/null || true

# ============================================================
# Display DNS Record
# ============================================================
echo ""
echo "============================================================"
echo "  DKIM DNS Record for ${DOMAIN}"
echo "============================================================"
echo ""
echo "Add this TXT record to your DNS:"
echo ""
echo "  Name:  ${SELECTOR}._domainkey.${DOMAIN}"
echo "  Type:  TXT"
echo ""

if [ -f "${KEY_DIR}/${SELECTOR}.txt" ]; then
    echo "  Value:"
    cat "${KEY_DIR}/${SELECTOR}.txt"
else
    # Fallback display
    PUBLIC_KEY=$(cat "${KEY_DIR}/${SELECTOR}.public" | \
        sed -n '/-----BEGIN PUBLIC KEY-----/,/-----END PUBLIC KEY-----/p' | \
        grep -v "PUBLIC KEY" | tr -d '\n')
    echo "  Value:"
    echo "  \"v=DKIM1; k=rsa; p=${PUBLIC_KEY}\""
fi

echo ""
echo "============================================================"
echo ""
echo "DKIM keys generated successfully."
echo "  Domain:   ${DOMAIN}"
echo "  Selector: ${SELECTOR}"
echo "  Key dir:  ${KEY_DIR}"
echo ""