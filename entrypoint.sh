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
    "/etc/opendkim/opendkim.conf"
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
# Validate DKIM keys and tables
# ============================================================
if grep -q "milter_default_action = accept" /etc/postfix/main.cf 2>/dev/null; then
    log "DKIM is configured, checking keys and tables..."

    # Auto-regenerate DKIM tables if they still have example.com placeholder
    if grep -q "example.com" /etc/opendkim/KeyTable 2>/dev/null; then
        log "DKIM tables contain example.com placeholder - regenerating for $POSTFIX_DOMAIN..."

        # Discover DKIM selector from existing keys
        DKIM_SELECTOR=""
        if [ -d "/data/dkim/${POSTFIX_DOMAIN}" ]; then
            for keyfile in "/data/dkim/${POSTFIX_DOMAIN}/"*.private; do
                if [ -f "$keyfile" ]; then
                    DKIM_SELECTOR=$(basename "$keyfile" .private)
                    log "  Found DKIM key: selector=$DKIM_SELECTOR, domain=$POSTFIX_DOMAIN"
                    break
                fi
            done
        fi

        # Fallback selector if no keys found
        if [ -z "$DKIM_SELECTOR" ]; then
            DKIM_SELECTOR="mail"
            log "  No DKIM keys found, using default selector: $DKIM_SELECTOR"
        fi

        # Regenerate TrustedHosts
        cat > /etc/opendkim/TrustedHosts << TRUSTEDEOF
127.0.0.1
::1
localhost
${POSTFIX_DOMAIN}
${POSTFIX_HOSTNAME}
TRUSTEDEOF
        log "  Regenerated /etc/opendkim/TrustedHosts"

        # Regenerate KeyTable
        cat > /etc/opendkim/KeyTable << KEYEOF
${DKIM_SELECTOR}._domainkey.${POSTFIX_DOMAIN}:${POSTFIX_DOMAIN}:${DKIM_SELECTOR}:/etc/opendkim/keys/${POSTFIX_DOMAIN}/${DKIM_SELECTOR}.private
KEYEOF
        log "  Regenerated /etc/opendkim/KeyTable"

        # Regenerate SigningTable
        cat > /etc/opendkim/SigningTable << SIGNEOF
${POSTFIX_DOMAIN} ${DKIM_SELECTOR}._domainkey.${POSTFIX_DOMAIN}
SIGNEOF
        log "  Regenerated /etc/opendkim/SigningTable"
    fi

    # Copy DKIM keys from volume to opendkim config directory
    if [ -d "/data/dkim" ] && [ "$(ls -A /data/dkim 2>/dev/null)" ]; then
        log "Copying DKIM keys from /data/dkim..."
        for domain_dir in /data/dkim/*/; do
            if [ -d "$domain_dir" ]; then
                domain=$(basename "$domain_dir")
                mkdir -p "/etc/opendkim/keys/$domain"
                cp -u "$domain_dir"* "/etc/opendkim/keys/$domain/" 2>/dev/null || true
                chown -R opendkim:opendkim "/etc/opendkim/keys/$domain"
                chmod -R 600 "/etc/opendkim/keys/$domain"
                log "  Copied DKIM keys for domain: $domain"
            fi
        done
    else
        log "WARNING: No DKIM keys found in /data/dkim"
    fi
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

# Update Postfix TLS paths
if [ -f "/data/certs/mail.crt" ] && [ -f "/data/certs/mail.key" ]; then
    postconf -e "smtpd_tls_cert_file = /data/certs/mail.crt" 2>/dev/null || true
    postconf -e "smtpd_tls_key_file = /data/certs/mail.key" 2>/dev/null || true
    log "TLS certificates configured."
fi

# ============================================================
# Create smtpusers group for SMTP authentication
# ============================================================
log "Creating smtpusers group..."
if ! getent group smtpusers > /dev/null 2>&1; then
    groupadd -r smtpusers
    log "  Created 'smtpusers' group"
else
    log "  Group 'smtpusers' already exists"
fi

# ============================================================
# Configure PAM for SMTP SASL authentication
# ============================================================
log "Configuring PAM for SMTP authentication..."
mkdir -p /etc/pam.d
cat > /etc/pam.d/smtp << 'PAMSMTP'
#
# PAM configuration for SMTP SASL authentication
# Uses local system accounts with nologin shell
#
auth    required    pam_unix.so    nullok_secure
account required    pam_unix.so
PAMSMTP
log "  PAM service 'smtp' configured"

# CRITICAL: pam_unix.so account module checks that the user's shell is listed
# in /etc/shells. SMTP users have /usr/sbin/nologin which is NOT in /etc/shells
# by default on Debian. Without this, all auth is rejected even with correct password.
if ! grep -qx '/usr/sbin/nologin' /etc/shells 2>/dev/null; then
    echo '/usr/sbin/nologin' >> /etc/shells
    log "  Added /usr/sbin/nologin to /etc/shells (required for PAM account check)"
fi

# Ensure saslauthd can read shadow if needed
if ! groups saslauthd 2>/dev/null | grep -qw shadow 2>/dev/null; then
    usermod -aG shadow saslauthd 2>/dev/null || true
fi

# ============================================================
# Create SMTP users from persistent volume
# ============================================================
if [ -f "/data/users/smtp-users" ] && [ -s "/data/users/smtp-users" ]; then
    log "Creating SMTP users from /data/users/smtp-users..."

    while IFS=: read -r username password_or_hash extra1 extra2; do
        [ -z "$username" ] && continue

        # Skip comments
        case "$username" in
            \#*) continue ;;
        esac

        plaintext_password=""
        pre_hashed=""

        if [ -n "$extra2" ]; then
            # Legacy: 4 fields (username:hash:uid:gid)
            pre_hashed="$password_or_hash"
        else
            # New format: 2 fields (username:password) - plaintext
            plaintext_password="$password_or_hash"
        fi

        # Create user if not exists
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

        # Set password: chpasswd directly on plaintext (system handles hashing
        # with PAM-compatible crypt). For pre-hashed, use chpasswd -e.
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
        else
            log "  ERROR: No password available for '$username'"
        fi
    done < /data/users/smtp-users
    log "SMTP users configured."
else
    log "No SMTP users file found at /data/users/smtp-users"
    log "Create users with: docker exec smtp-relay add-smtp-user <username>"
fi

# ============================================================
# Ensure correct permissions
# ============================================================
log "Setting file permissions..."

chown -R root:root /etc/postfix
chmod 644 /etc/postfix/main.cf /etc/postfix/master.cf 2>/dev/null || true
chmod 640 /etc/postfix/sasl/smtpd.conf 2>/dev/null || true

chown -R opendkim:opendkim /etc/opendkim
chmod -R 700 /etc/opendkim/keys 2>/dev/null || true

# CRITICAL: Postfix needs access to the OpenDKIM milter socket.
# The socket directory is chown opendkim:opendkim with 750 perms.
# Postfix runs as 'postfix' user; adding it to opendkim group grants access.
if ! groups postfix 2>/dev/null | grep -qw opendkim; then
    usermod -aG opendkim postfix 2>/dev/null || true
    log "  Added postfix user to opendkim group (required for DKIM socket access)"
fi

# Ensure socket directory has group-read-execute so postfix (in opendkim group) can access
chmod 750 /var/spool/postfix/var/run/opendkim 2>/dev/null || true
chown opendkim:opendkim /var/spool/postfix/var/run/opendkim 2>/dev/null || true

chmod 700 /data/dkim /data/certs /data/users 2>/dev/null || true

mkdir -p /var/run/opendkim
chown opendkim:opendkim /var/run/opendkim
chmod 755 /var/run/opendkim

mkdir -p /var/run/saslauthd
mkdir -p /var/spool/postfix/var/run/saslauthd
chown saslauthd:saslauthd /var/run/saslauthd /var/spool/postfix/var/run/saslauthd 2>/dev/null || true
chmod 755 /var/run/saslauthd /var/spool/postfix/var/run/saslauthd

# ============================================================
# Start rsyslog
# ============================================================
log "Starting rsyslog..."
rsyslogd
sleep 1
if pgrep rsyslogd > /dev/null; then
    log "rsyslog started successfully."
else
    log "WARNING: rsyslog failed to start."
fi

# ============================================================
# Start saslauthd (SASL authentication daemon)
# ============================================================
log "Starting saslauthd..."
chown saslauthd:saslauthd /var/run/saslauthd 2>/dev/null || true
chmod 755 /var/run/saslauthd

saslauthd -a pam -c -m /var/run/saslauthd -O pam_service=smtp
sleep 2

if pgrep saslauthd > /dev/null; then
    log "saslauthd started successfully (PAM mechanism)."

    # Verify SASL users
    if [ -f "/data/users/smtp-users" ] && [ -s "/data/users/smtp-users" ]; then
        log "Verifying SASL users..."
        SASL_AUTH_FAILED=0
        while IFS=: read -r username password_or_hash extra1 extra2; do
            [ -z "$username" ] && continue
            case "$username" in \#*) continue ;; esac

            if id "$username" &>/dev/null; then
                if testsaslauthd -u "$username" -p "test" -f /var/run/saslauthd/mux -r smtp 2>/dev/null; then
                    log "  WARNING: testsaslauthd returned unexpected OK for '$username' (test pass)"
                else
                    log "  User '$username' exists and PAM service is responding"
                fi
            else
                log "  WARNING: User '$username' not in system, SASL auth will fail"
                SASL_AUTH_FAILED=1
            fi
        done < /data/users/smtp-users
        [ "$SASL_AUTH_FAILED" -eq 0 ] && log "All SASL users verified successfully."
    fi
else
    log "WARNING: saslauthd failed to start."
fi

# ============================================================
# Start OpenDKIM
# ============================================================
log "Starting OpenDKIM..."
chown opendkim:opendkim /var/run/opendkim 2>/dev/null || true

opendkim -x /etc/opendkim/opendkim.conf
sleep 1
if pgrep opendkim > /dev/null; then
    log "OpenDKIM started successfully."
else
    log "WARNING: OpenDKIM failed to start."
fi

# ============================================================
# Start Postfix
# ============================================================
log "Starting Postfix..."
postfix start
sleep 1
if pgrep master > /dev/null; then
    log "Postfix started successfully."
else
    log "WARNING: Postfix failed to start."
fi

# ============================================================
# Print summary
# ============================================================
log "============================================================"
log "SMTP Relay is running!"
log "  Port: 587 (Submission)"
log "  Domain: $POSTFIX_DOMAIN"
log "  Hostname: $POSTFIX_HOSTNAME"
log "  TLS: $([ -f /data/certs/mail.crt ] && echo 'enabled' || echo 'self-signed')"
log "  SASL: $(pgrep saslauthd > /dev/null && echo 'running (PAM)' || echo 'NOT running')"
log "  DKIM: $(pgrep opendkim > /dev/null && echo 'running' || echo 'NOT running')"

# Show DKIM signing domain
if grep -q "milter_default_action = accept" /etc/postfix/main.cf 2>/dev/null; then
    dkim_domain=$(grep -v '^#' /etc/opendkim/SigningTable 2>/dev/null | awk '{print $1}' | head -1)
    [ -n "$dkim_domain" ] && log "  DKIM signing: $dkim_domain"
fi

log "  Relay: $(postconf -h relayhost 2>/dev/null | head -1 || echo 'direct delivery')"
log "============================================================"

# ============================================================
# Keep container running and follow logs
# ============================================================
log "Following logs..."

tail -F /var/log/mail.log /var/log/syslog /var/log/auth.log 2>/dev/null &
TAIL_PID=$!

cleanup() {
    log "Shutting down services..."
    postfix stop 2>/dev/null || true
    killall opendkim 2>/dev/null || true
    killall saslauthd 2>/dev/null || true
    kill $TAIL_PID 2>/dev/null || true
    log "Shutdown complete."
    exit 0
}

trap cleanup SIGTERM SIGINT

wait $TAIL_PID 2>/dev/null || cleanup