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
# Validate DKIM keys if DKIM is configured
# ============================================================
if grep -q "milter_default_action = accept" /etc/postfix/main.cf 2>/dev/null; then
    log "DKIM is configured, checking keys..."
    
    if [ -d "/data/dkim" ] && [ "$(ls -A /data/dkim 2>/dev/null)" ]; then
        log "DKIM keys found in /data/dkim"
        
        for domain_dir in /data/dkim/*/; do
            if [ -d "$domain_dir" ]; then
                domain=$(basename "$domain_dir")
                mkdir -p "/etc/opendkim/keys/$domain"
                cp -u "$domain_dir"* "/etc/opendkim/keys/$domain/" 2>/dev/null || true
                chown -R opendkim:opendkim "/etc/opendkim/keys/$domain"
                chmod -R 600 "/etc/opendkim/keys/$domain"
            fi
        done
    else
        log "WARNING: DKIM is configured but no keys found in /data/dkim"
        log "DKIM signing will not work without keys. Run install.sh to generate keys."
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
# Users must be in the 'smtpusers' group
#
auth    required    pam_unix.so    nullok_secure
account required    pam_unix.so
PAMSMTP
log "  PAM service 'smtp' configured"

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
        
        password_hash=""
        
        # Detect format: 2 fields = plaintext (username:password)
        #                4 fields = pre-hashed (username:hash:uid:gid) -- legacy
        if [ -n "$extra2" ]; then
            # Legacy format: pre-hashed with uid/gid fields
            password_hash="$password_or_hash"
        else
            # New format: plaintext - hash it now, inside the container
            # This ensures crypt library compatibility with the container's OS
            password_hash=$(openssl passwd -6 "$password_or_hash" 2>/dev/null)
            if [ -z "$password_hash" ]; then
                log "  ERROR: Failed to hash password for '$username'"
                continue
            fi
        fi
        
        # Create user if not exists, with nologin shell and smtpusers group
        if ! id "$username" &>/dev/null; then
            if useradd_out=$(useradd -M -s /usr/sbin/nologin -d "/home/$username" -G smtpusers "$username" 2>&1); then
                log "  Created system user: $username (shell: /usr/sbin/nologin, group: smtpusers)"
            else
                log "  ERROR: Failed to create system user '$username': $useradd_out"
                continue
            fi
        else
            # Ensure existing user is in smtpusers group
            if ! groups "$username" 2>/dev/null | grep -qw smtpusers; then
                usermod -aG smtpusers "$username" 2>/dev/null || true
                log "  Added $username to smtpusers group"
            fi
        fi
        
        # Set password from hash
        if [ -n "$password_hash" ]; then
            if echo "${username}:${password_hash}" | chpasswd -e 2>&1; then
                log "  Set password for: $username"
            else
                log "  ERROR: Failed to set password for '$username' (hash may not be compatible with this container's crypt lib)"
            fi
        else
            log "  ERROR: No password/hash available for '$username'"
        fi
    done < /data/users/smtp-users
    log "SMTP users configured."
else
    log "No SMTP users file found at /data/users/smtp-users"
    log "Create users by running: docker exec smtp-relay add-smtp-user <username>"
fi

# ============================================================
# Ensure correct permissions
# ============================================================
log "Setting file permissions..."

# Postfix
chown -R root:root /etc/postfix
chmod 644 /etc/postfix/main.cf /etc/postfix/master.cf 2>/dev/null || true
chmod 640 /etc/postfix/sasl/smtpd.conf 2>/dev/null || true

# OpenDKIM
chown -R opendkim:opendkim /etc/opendkim
chmod -R 700 /etc/opendkim/keys 2>/dev/null || true

# Data directories
chmod 700 /data/dkim /data/certs /data/users 2>/dev/null || true

# OpenDKIM run directory
mkdir -p /var/run/opendkim
chown opendkim:opendkim /var/run/opendkim
chmod 755 /var/run/opendkim

# saslauthd run directories
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

# Ensure correct ownership of saslauthd socket directory
chown saslauthd:saslauthd /var/run/saslauthd 2>/dev/null || true
chmod 755 /var/run/saslauthd

saslauthd -a pam -c -m /var/run/saslauthd -O pam_service=smtp
sleep 2

if pgrep saslauthd > /dev/null; then
    log "saslauthd started successfully (PAM mechanism)."
    
    # ============================================================
    # Verify SASL users if any exist
    # ============================================================
    if [ -f "/data/users/smtp-users" ] && [ -s "/data/users/smtp-users" ]; then
        log "Verifying SASL users..."
        SASL_AUTH_FAILED=0
        while IFS=: read -r username password_or_hash extra1 extra2; do
            [ -z "$username" ] && continue
            case "$username" in
                \#*) continue ;;
            esac
            
            if id "$username" &>/dev/null; then
                # Quick sanity check: does the PAM service respond for this user?
                if testsaslauthd -u "$username" -p "test" -f /var/run/saslauthd/mux -r smtp 2>/dev/null; then
                    log "  WARNING: testsaslauthd returned unexpected OK for '$username' with test password"
                else
                    log "  User '$username' exists and PAM service is responding"
                fi
            else
                log "  WARNING: User '$username' not found in system, SASL auth will fail"
                SASL_AUTH_FAILED=1
            fi
        done < /data/users/smtp-users
        
        if [ "$SASL_AUTH_FAILED" -eq 0 ]; then
            log "All SASL users verified successfully."
        else
            log "WARNING: Some SASL users may not be properly configured. Check logs for details."
        fi
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
SASL_AUTH=$(grep -c 'smtpd_sasl_auth_enable' /etc/postfix/main.cf 2>/dev/null || echo 0)

log "============================================================"
log "SMTP Relay is running!"
log "  - Submission port: 587"
log "  - TLS: enabled ($([ -f /data/certs/mail.crt ] && echo 'certificate found' || echo 'self-signed'))"
log "  - SASL: $(pgrep saslauthd > /dev/null && echo 'running (PAM: local users)' || echo 'not running')"
log "  - DKIM: $(pgrep opendkim > /dev/null && echo 'running' || echo 'not running')"
log "  - Relay: $(postconf -h relayhost 2>/dev/null | head -1 || echo 'direct')"
log "============================================================"

# ============================================================
# Keep container running and follow logs
# ============================================================
log "Following logs (Ctrl+C to stop)..."

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