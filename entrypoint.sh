#!/bin/bash
set -e

# ============================================================
# SMTP Relay Entrypoint Script
# Starts rsyslog, saslauthd, OpenDKIM, and Postfix
# ============================================================

LOG_PREFIX="[smtp-relay]"

log() {
    echo "$LOG_PREFIX $(date '+%Y-%m-%d %H:%M:%S') $1"
}

log "Starting SMTP relay initialization..."

# ============================================================
# Validate required configuration files
# ============================================================
log "Validating configuration files..."

REQUIRED_FILES=(
    "/etc/postfix/main.cf"
    "/etc/postfix/master.cf"
    "/etc/postfix/sasl/smtpd.conf"
    "/etc/opendkim.conf"
)

MISSING=0
for f in "${REQUIRED_FILES[@]}"; do
    if [ ! -f "$f" ]; then
        log "ERROR: Missing required config file: $f"
        MISSING=1
    fi
done
if [ "$MISSING" -eq 1 ]; then
    log "FATAL: Required configuration files are missing. Please run install.sh first."
    exit 1
fi

# ============================================================
# Read domain and hostname from Postfix config
# ============================================================
POSTFIX_DOMAIN=$(postconf -h mydomain 2>/dev/null || echo "example.com")
POSTFIX_HOSTNAME=$(postconf -h myhostname 2>/dev/null || echo "mail.example.com")
log "Postfix domain: $POSTFIX_DOMAIN"
log "Postfix hostname: $POSTFIX_HOSTNAME"

# ============================================================
# DKIM: Discover or generate keys, then write consistent tables
# ============================================================
if grep -q "milter_default_action = accept" /etc/postfix/main.cf 2>/dev/null; then
    log "DKIM is configured."

    DKIM_SELECTOR=""

    # First, try to find existing keys in /data/dkim/<domain>/
    if [ -d "/data/dkim/${POSTFIX_DOMAIN}" ]; then
        for keyfile in "/data/dkim/${POSTFIX_DOMAIN}/"*.private; do
            if [ -f "$keyfile" ]; then
                DKIM_SELECTOR=$(basename "$keyfile" .private)
                log "  Found existing DKIM key: selector=$DKIM_SELECTOR"
                break
            fi
        done
    fi

    # If no keys found, generate them now (opendkim-genkey is in the container)
    if [ -z "$DKIM_SELECTOR" ]; then
        DKIM_SELECTOR="mail"
        log "  No DKIM keys found - generating new keys (selector=$DKIM_SELECTOR, domain=$POSTFIX_DOMAIN)..."
        mkdir -p "/data/dkim/${POSTFIX_DOMAIN}"

        if command -v opendkim-genkey &>/dev/null; then
            opendkim-genkey -b 2048 -d "$POSTFIX_DOMAIN" -D "/data/dkim/${POSTFIX_DOMAIN}" -s "$DKIM_SELECTOR"
            log "  Generated DKIM key pair via opendkim-genkey"
        else
            # Fallback: generate with openssl
            openssl genrsa -out "/data/dkim/${POSTFIX_DOMAIN}/${DKIM_SELECTOR}.private" 2048 2>/dev/null
            openssl rsa -in "/data/dkim/${POSTFIX_DOMAIN}/${DKIM_SELECTOR}.private" \
                -pubout -out "/data/dkim/${POSTFIX_DOMAIN}/${DKIM_SELECTOR}.public" 2>/dev/null
            log "  Generated DKIM key pair via openssl"
        fi

        chmod 600 "/data/dkim/${POSTFIX_DOMAIN}/${DKIM_SELECTOR}.private"
        # Print DNS record for user
        log "========================================================"
        log "  ADD THIS TXT RECORD TO YOUR DNS:"
        log "  Name:  ${DKIM_SELECTOR}._domainkey.${POSTFIX_DOMAIN}"
        log "  Type:  TXT"
        if [ -f "/data/dkim/${POSTFIX_DOMAIN}/${DKIM_SELECTOR}.txt" ]; then
            log "  Value: $(cat /data/dkim/${POSTFIX_DOMAIN}/${DKIM_SELECTOR}.txt)"
        fi
        log "========================================================"
    fi

    # Always regenerate tables from the discovered/generated selector
    log "Regenerating DKIM tables (domain=$POSTFIX_DOMAIN, selector=$DKIM_SELECTOR)..."

    cat > /etc/opendkim/TrustedHosts << TRUSTEDEOF
127.0.0.1
::1
localhost
${POSTFIX_DOMAIN}
${POSTFIX_HOSTNAME}
TRUSTEDEOF

    cat > /etc/opendkim/KeyTable << KEYEOF
${DKIM_SELECTOR}._domainkey.${POSTFIX_DOMAIN}:${POSTFIX_DOMAIN}:${DKIM_SELECTOR}:/etc/opendkim/keys/${POSTFIX_DOMAIN}/${DKIM_SELECTOR}.private
KEYEOF

    cat > /etc/opendkim/SigningTable << SIGNEOF
*@${POSTFIX_DOMAIN} ${DKIM_SELECTOR}._domainkey.${POSTFIX_DOMAIN}
SIGNEOF

    log "  DKIM tables regenerated."

    # Copy keys from volume to opendkim config directory
    log "Copying DKIM keys to /etc/opendkim/keys/..."
    for domain_dir in /data/dkim/*/; do
        if [ -d "$domain_dir" ]; then
            domain=$(basename "$domain_dir")
            mkdir -p "/etc/opendkim/keys/$domain"
            cp "$domain_dir"* "/etc/opendkim/keys/$domain/" 2>/dev/null || true
            chown -R opendkim:opendkim "/etc/opendkim/keys/$domain"
            chmod -R 600 "/etc/opendkim/keys/$domain"
            log "  Copied keys for domain: $domain"
        fi
    done
fi

# ============================================================
# Validate TLS certificates
# ============================================================
log "Checking TLS certificates..."
if [ ! -f "/data/certs/mail.crt" ] || [ ! -f "/data/certs/mail.key" ]; then
    log "WARNING: TLS certificates not found. Generating self-signed certificate..."
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout /data/certs/mail.key \
        -out /data/certs/mail.crt \
        -subj "/C=US/ST=Local/L=Local/O=SMTP-Relay/CN=$(hostname)" 2>/dev/null
    chmod 600 /data/certs/mail.key
    chmod 644 /data/certs/mail.crt
    log "Self-signed certificate generated."
fi

if [ -f "/data/certs/mail.crt" ] && [ -f "/data/certs/mail.key" ]; then
    postconf -e "smtpd_tls_cert_file = /data/certs/mail.crt" 2>/dev/null || true
    postconf -e "smtpd_tls_key_file = /data/certs/mail.key" 2>/dev/null || true
    log "TLS certificates configured."
fi

# ============================================================
# Create smtpusers group
# ============================================================
log "Creating smtpusers group..."
if ! getent group smtpusers > /dev/null 2>&1; then
    groupadd -r smtpusers
    log "  Created 'smtpusers' group"
fi

# ============================================================
# Configure PAM + add nologin to /etc/shells
# ============================================================
log "Configuring PAM for SMTP authentication..."
mkdir -p /etc/pam.d
cat > /etc/pam.d/smtp << 'PAMSMTP'
auth    required    pam_unix.so    nullok_secure
account required    pam_unix.so
PAMSMTP

if ! grep -qx '/usr/sbin/nologin' /etc/shells 2>/dev/null; then
    echo '/usr/sbin/nologin' >> /etc/shells
    log "  Added /usr/sbin/nologin to /etc/shells"
fi

if ! groups saslauthd 2>/dev/null | grep -qw shadow 2>/dev/null; then
    usermod -aG shadow saslauthd 2>/dev/null || true
fi

# ============================================================
# Create SMTP users
# ============================================================
if [ -f "/data/users/smtp-users" ] && [ -s "/data/users/smtp-users" ]; then
    log "Creating SMTP users from /data/users/smtp-users..."

    while IFS=: read -r username password_or_hash extra1 extra2; do
        [ -z "$username" ] && continue
        case "$username" in \#*) continue ;; esac

        plaintext_password=""
        pre_hashed=""

        if [ -n "$extra2" ]; then
            pre_hashed="$password_or_hash"
        else
            plaintext_password="$password_or_hash"
        fi

        if ! id "$username" &>/dev/null; then
            if useradd_out=$(useradd -M -s /usr/sbin/nologin -d "/home/$username" -G smtpusers "$username" 2>&1); then
                log "  Created system user: $username"
            else
                log "  ERROR: Failed to create system user '$username': $useradd_out"
                continue
            fi
        else
            if ! groups "$username" 2>/dev/null | grep -qw smtpusers; then
                usermod -aG smtpusers "$username" 2>/dev/null || true
                log "  Added $username to smtpusers group"
            fi
        fi

        if [ -n "$plaintext_password" ]; then
            if echo "${username}:${plaintext_password}" | chpasswd 2>&1; then
                log "  Set password for: $username"
            else
                log "  ERROR: Failed to set password for '$username'"
            fi
        elif [ -n "$pre_hashed" ]; then
            if echo "${username}:${pre_hashed}" | chpasswd -e 2>&1; then
                log "  Set password for: $username (legacy hash)"
            else
                log "  ERROR: Failed to set password for '$username' from legacy hash"
            fi
        fi
    done < /data/users/smtp-users
    log "SMTP users configured."
else
    log "No SMTP users file found at /data/users/smtp-users"
fi

# ============================================================
# Permissions
# ============================================================
log "Setting file permissions..."

chown -R root:root /etc/postfix
chmod 644 /etc/postfix/main.cf /etc/postfix/master.cf 2>/dev/null || true
chmod 640 /etc/postfix/sasl/smtpd.conf 2>/dev/null || true

chown -R opendkim:opendkim /etc/opendkim
chmod -R 700 /etc/opendkim/keys 2>/dev/null || true

# DKIM socket directory: opendkim:postfix with setgid (2770).
# OpenDKIM runs as opendkim:opendkim, but setgid ensures the socket file
# inherits the 'postfix' group, letting Postfix connect without joining
# the opendkim group (which would break OpenDKIM's key security check).
mkdir -p /var/spool/postfix/opendkim
chown opendkim:postfix /var/spool/postfix/opendkim 2>/dev/null || true
chmod 2770 /var/spool/postfix/opendkim 2>/dev/null || true

chmod 700 /data/dkim /data/certs /data/users 2>/dev/null || true

mkdir -p /var/run/opendkim /var/run/saslauthd /var/spool/postfix/var/run/saslauthd
chown opendkim:opendkim /var/run/opendkim
chmod 755 /var/run/opendkim
chown saslauthd:saslauthd /var/run/saslauthd /var/spool/postfix/var/run/saslauthd 2>/dev/null || true
chmod 755 /var/run/saslauthd /var/spool/postfix/var/run/saslauthd

# ============================================================
# Start services
# ============================================================
log "Starting rsyslog..."
rsyslogd; sleep 1
pgrep rsyslogd > /dev/null && log "rsyslog started." || log "WARNING: rsyslog failed."

log "Starting saslauthd..."
chown saslauthd:saslauthd /var/run/saslauthd 2>/dev/null || true
chmod 755 /var/run/saslauthd
saslauthd -a pam -c -m /var/run/saslauthd -O pam_service=smtp
sleep 2
if pgrep saslauthd > /dev/null; then
    log "saslauthd started (PAM)."
else
    log "WARNING: saslauthd failed to start."
fi

log "Starting OpenDKIM..."
chown opendkim:opendkim /var/run/opendkim 2>/dev/null || true
opendkim -x /etc/opendkim.conf
sleep 1
pgrep opendkim > /dev/null && log "OpenDKIM started." || log "WARNING: OpenDKIM failed."

log "Starting Postfix..."
postfix start
sleep 1
pgrep master > /dev/null && log "Postfix started." || log "WARNING: Postfix failed."

# ============================================================
# Summary
# ============================================================
log "============================================================"
log "SMTP Relay is running!"
log "  Domain: $POSTFIX_DOMAIN"
log "  Port: 587 (submission)"
log "  SASL: $(pgrep saslauthd > /dev/null && echo 'PAM running' || echo 'OFF')"
log "  DKIM: $(pgrep opendkim > /dev/null && echo 'running' || echo 'OFF')"
if grep -q "milter_default_action = accept" /etc/postfix/main.cf 2>/dev/null; then
    dkim_domain=$(grep -v '^#' /etc/opendkim/SigningTable 2>/dev/null | awk '{print $1}' | head -1)
    dkim_selector=$(grep -v '^#' /etc/opendkim/SigningTable 2>/dev/null | awk '{print $2}' | head -1)
    [ -n "$dkim_domain" ] && log "  DKIM signing: $dkim_domain ($dkim_selector)"
fi
log "============================================================"

# ============================================================
# Keep container running
# ============================================================
log "Following logs..."

tail -F /var/log/mail.log /var/log/syslog /var/log/auth.log 2>/dev/null &
TAIL_PID=$!

cleanup() {
    log "Shutting down..."
    postfix stop 2>/dev/null || true
    killall opendkim 2>/dev/null || true
    killall saslauthd 2>/dev/null || true
    kill $TAIL_PID 2>/dev/null || true
    exit 0
}

trap cleanup SIGTERM SIGINT
wait $TAIL_PID 2>/dev/null || cleanup