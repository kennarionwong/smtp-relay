#!/bin/bash
# ============================================================
# SMTP Relay Interactive Installation Script
# Production-ready Docker-based SMTP relay setup
# ============================================================

set -e

# ============================================================
# Color definitions
# ============================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# ============================================================
# Helper functions
# ============================================================
log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
header()      { echo -e "\n${BOLD}${CYAN}===== $1 =====${NC}\n"; }

ask() {
    local prompt="$1"
    local default="${2:-}"
    local result
    
    if [ -n "$default" ]; then
        read -rp "$(echo -e "${BOLD}$prompt${NC} [$default]: ")" result
    else
        read -rp "$(echo -e "${BOLD}$prompt${NC}: ")" result
    fi
    
    echo "${result:-$default}"
}

ask_password() {
    local prompt="$1"
    local result
    
    read -srp "$(echo -e "${BOLD}$prompt${NC}: ")" result
    echo ""
    echo "$result"
}

ask_yn() {
    local prompt="$1"
    local default="${2:-y}"
    local hint="Y/n"
    
    if [ "$default" = "n" ] || [ "$default" = "N" ]; then
        hint="y/N"
    fi
    
    read -rp "$(echo -e "${BOLD}$prompt${NC} [$hint]: ")" result
    
    result="${result:-$default}"
    
    case "${result,,}" in
        y|yes) echo "y" ;;
        n|no)  echo "n" ;;
        *)     echo "${default}" ;;
    esac
}

# ============================================================
# Check prerequisites
# ============================================================
check_prerequisites() {
    header "Checking Prerequisites"
    
    # Check root
    if [ "$(id -u)" -ne 0 ]; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi
    log_success "Running as root"
    
    # Check Docker
    if command -v docker &> /dev/null; then
        log_success "Docker found: $(docker --version)"
    else
        log_warn "Docker not found - will generate configs only"
    fi
    
    # Check Docker Compose
    if command -v docker-compose &> /dev/null; then
        log_success "Docker Compose found: $(docker-compose --version)"
    elif docker compose version &> /dev/null 2>&1; then
        log_success "Docker Compose (v2) found: $(docker compose version)"
    else
        log_warn "Docker Compose not found - will generate compose file"
    fi
    
    # Check openssl
    if command -v openssl &> /dev/null; then
        log_success "OpenSSL found"
    else
        log_error "OpenSSL is required but not found"
        exit 1
    fi
}

# ============================================================
# Collect configuration
# ============================================================
collect_general_config() {
    header "General Configuration"
    
    echo -e "Configure your SMTP relay hostname and domain."
    echo -e "This is used for the server identity and DKIM signing.\n"
    
    DOMAIN=$(ask "Domain name (e.g., example.com)")
    
    if [ -z "$DOMAIN" ]; then
        log_error "Domain name is required"
        exit 1
    fi
    
    HOSTNAME=$(ask "Mail hostname" "mail.${DOMAIN}")
    log_info "Server hostname: ${HOSTNAME}"
    log_info "Domain: ${DOMAIN}"
}

collect_auth_config() {
    header "SMTP Authentication"
    
    ENABLE_AUTH=$(ask_yn "Enable SMTP authentication?" "y")
    
    USERS=()
    
    if [ "$ENABLE_AUTH" = "y" ]; then
        echo -e "\n${BOLD}Add SMTP users for SASL authentication:${NC}"
        
        local add_more="y"
        while [ "$add_more" = "y" ]; do
            local username
            local password
            local password_confirm
            
            echo -e "\n${CYAN}--- Add User ---${NC}"
            username=$(ask "  Username")
            
            if [ -z "$username" ]; then
                log_warn "Username cannot be empty, skipping"
                continue
            fi
            
            password=$(ask_password "  Password")
            
            if [ -z "$password" ]; then
                log_warn "Password cannot be empty, skipping"
                continue
            fi
            
            password_confirm=$(ask_password "  Confirm password")
            
            if [ "$password" != "$password_confirm" ]; then
                log_warn "Passwords do not match, skipping"
                continue
            fi
            
            # Check minimum password length
            if [ ${#password} -lt 8 ]; then
                log_warn "Password is less than 8 characters. Use a stronger password."
                local continue_anyway=$(ask_yn "  Continue with weak password?" "n")
                if [ "$continue_anyway" != "y" ]; then
                    continue
                fi
            fi
            
            USERS+=("${username}:${password}")
            log_success "  User '${username}' added"
            
            add_more=$(ask_yn "Add another user?" "n")
        done
        
        if [ ${#USERS[@]} -eq 0 ]; then
            log_warn "No users added. Disabling authentication."
            ENABLE_AUTH="n"
        else
            log_success "Total users configured: ${#USERS[@]}"
        fi
    fi
}

collect_relay_config() {
    header "Relay Configuration"
    
    echo -e "Configure mail relay. You can deliver directly or relay through an upstream provider."
    echo -e "Relay providers: Gmail Workspace, Amazon SES, SendGrid, Mailgun, SMTP2GO, Office365\n"
    
    ENABLE_RELAY=$(ask_yn "Relay mail through an upstream SMTP server?" "n")
    
    if [ "$ENABLE_RELAY" = "y" ]; then
        echo ""
        echo -e "${CYAN}Select your relay provider (or enter custom settings):${NC}"
        echo "  1) Custom / Generic SMTP relay"
        echo "  2) Gmail Workspace (smtp.gmail.com:587)"
        echo "  3) Amazon SES (email-smtp.region.amazonaws.com:587)"
        echo "  4) SendGrid (smtp.sendgrid.net:587)"
        echo "  5) Mailgun (smtp.mailgun.org:587)"
        echo "  6) SMTP2GO (smtp.smtp2go.com:587)"
        echo "  7) Office365 (smtp.office365.com:587)"
        echo ""
        
        RELAY_PROVIDER=$(ask "Select provider" "1")
        
        case "$RELAY_PROVIDER" in
            2) # Gmail
                RELAY_HOST="smtp.gmail.com"
                RELAY_PORT="587"
                ;;
            3) # Amazon SES
                REGION=$(ask "AWS Region (e.g., us-east-1)" "us-east-1")
                RELAY_HOST="email-smtp.${REGION}.amazonaws.com"
                RELAY_PORT="587"
                ;;
            4) # SendGrid
                RELAY_HOST="smtp.sendgrid.net"
                RELAY_PORT="587"
                ;;
            5) # Mailgun
                RELAY_HOST="smtp.mailgun.org"
                RELAY_PORT="587"
                ;;
            6) # SMTP2GO
                RELAY_HOST="smtp.smtp2go.com"
                RELAY_PORT="587"
                ;;
            7) # Office365
                RELAY_HOST="smtp.office365.com"
                RELAY_PORT="587"
                ;;
            *) # Custom
                RELAY_HOST=$(ask "Relay hostname")
                RELAY_PORT=$(ask "Relay port" "587")
                ;;
        esac
        
        RELAY_USERNAME=$(ask "Relay username")
        RELAY_PASSWORD=$(ask_password "Relay password")
        
        RELAY_TLS=$(ask_yn "Use TLS?" "y")
        RELAY_STARTTLS=$(ask_yn "Require STARTTLS?" "y")
        
        log_success "Relay configured: ${RELAY_HOST}:${RELAY_PORT}"
    fi
}

collect_dkim_config() {
    header "DKIM Configuration"
    
    echo -e "Configure DomainKeys Identified Mail (DKIM) for email signing."
    echo -e "This adds a digital signature to outgoing emails.\n"
    
    ENABLE_DKIM=$(ask_yn "Enable DKIM signing?" "y")
    
    if [ "$ENABLE_DKIM" = "y" ]; then
        DKIM_DOMAIN="$DOMAIN"
        DKIM_SELECTOR=$(ask "DKIM selector" "mail")
        DKIM_KEY_SIZE=$(ask "Key size (bits)" "2048")
        
        if [ "$DKIM_KEY_SIZE" -lt 1024 ] 2>/dev/null; then
            log_warn "Key size less than 1024 bits is not recommended. Using 2048."
            DKIM_KEY_SIZE="2048"
        fi
        
        log_success "DKIM domain: ${DKIM_DOMAIN}"
        log_success "DKIM selector: ${DKIM_SELECTOR}"
        log_success "DKIM key size: ${DKIM_KEY_SIZE}"
    fi
}

collect_tls_config() {
    header "TLS Configuration"
    
    echo -e "Configure TLS certificates for encrypted connections.\n"
    echo "  1) Self-signed certificate (auto-generated)"
    echo "  2) Existing certificate files"
    echo "  3) Let's Encrypt compatible path"
    echo ""
    
    TLS_OPTION=$(ask "TLS certificate source" "1")
    
    case "$TLS_OPTION" in
        1)
            TLS_TYPE="self-signed"
            log_info "Will generate self-signed certificate"
            ;;
        2)
            TLS_TYPE="existing"
            TLS_CERT_PATH=$(ask "Path to certificate file")
            TLS_KEY_PATH=$(ask "Path to private key file")
            
            if [ ! -f "$TLS_CERT_PATH" ] || [ ! -f "$TLS_KEY_PATH" ]; then
                log_error "Certificate or key file not found"
                exit 1
            fi
            log_success "Using existing certificate: ${TLS_CERT_PATH}"
            ;;
        3)
            TLS_TYPE="letsencrypt"
            TLS_LE_PATH=$(ask "Let's Encrypt certificate path" "/etc/letsencrypt/live/mail.${DOMAIN}")
            log_success "Using Let's Encrypt: ${TLS_LE_PATH}"
            ;;
        *)
            log_error "Invalid option"
            exit 1
            ;;
    esac
}

# ============================================================
# Generate configuration files
# ============================================================
generate_postfix_config() {
    header "Generating Postfix Configuration"
    
    local main_cf="configs/postfix/main.cf"
    local master_cf="configs/postfix/master.cf"
    
    mkdir -p configs/postfix
    
    # Generate main.cf
    cat > "$main_cf" << 'POSTFIX_MAIN_HEADER'
# ============================================================
# Postfix Main Configuration
# Generated by install.sh
# ============================================================

# General
compatibility_level = 3.6
smtpd_banner = $myhostname ESMTP
biff = no
append_dot_mydomain = no
readme_directory = no

# Mail queue
maximal_queue_lifetime = 1d
bounce_queue_lifetime = 1d
maximal_backoff_time = 4000s
minimal_backoff_time = 300s
queue_run_delay = 300s

# Message size limit (50MB)
message_size_limit = 52428800

# Mailbox size limit (0 = unlimited)
mailbox_size_limit = 0

POSTFIX_MAIN_HEADER
    
    # Hostname and domain
    cat >> "$main_cf" << EOF
# Hostname and domain
myhostname = ${HOSTNAME}
mydomain = ${DOMAIN}
myorigin = \$mydomain
mydestination = \$myhostname, localhost.\$mydomain, localhost
mynetworks = 127.0.0.0/8

EOF
    
    # Recipient restrictions
    cat >> "$main_cf" << 'POSTFIX_RECIPIENT'
# Recipient restrictions
smtpd_recipient_restrictions =
    permit_sasl_authenticated,
    permit_mynetworks,
    reject_unauth_destination

POSTFIX_RECIPIENT
    
    # TLS
    cat >> "$main_cf" << 'POSTFIX_TLS'
# ============================================================
# TLS Configuration
# ============================================================
smtpd_tls_security_level = may
smtpd_tls_auth_only = yes
smtpd_tls_cert_file = /data/certs/mail.crt
smtpd_tls_key_file = /data/certs/mail.key
smtpd_tls_protocols = !SSLv2, !SSLv3, !TLSv1, !TLSv1.1
smtpd_tls_mandatory_protocols = !SSLv2, !SSLv3, !TLSv1, !TLSv1.1
smtpd_tls_ciphers = medium
smtpd_tls_mandatory_ciphers = high
smtpd_tls_loglevel = 1
smtpd_tls_received_header = yes

# Client-side TLS (outgoing)
smtp_tls_security_level = may
smtp_tls_protocols = !SSLv2, !SSLv3, !TLSv1, !TLSv1.1
smtp_tls_mandatory_protocols = !SSLv2, !SSLv3, !TLSv1, !TLSv1.1
smtp_tls_ciphers = medium
smtp_tls_mandatory_ciphers = high
smtp_tls_loglevel = 1
smtp_tls_note_starttls_offer = yes

POSTFIX_TLS
    
    # SASL
    if [ "$ENABLE_AUTH" = "y" ]; then
        cat >> "$main_cf" << 'POSTFIX_SASL'
# ============================================================
# SASL Authentication (via Cyrus SASL + PAM)
# ============================================================
smtpd_sasl_auth_enable = yes
smtpd_sasl_type = cyrus
smtpd_sasl_path = smtpd
smtpd_sasl_security_options = noanonymous, noplaintext
smtpd_sasl_tls_security_options = noanonymous
smtpd_sasl_local_domain = $myhostname
smtpd_sasl_authenticated_header = yes

# Postfix SMTP AUTH configuration
broken_sasl_auth_clients = yes
smtpd_sasl_service = smtp
cyrus_sasl_config_path = /etc/postfix/sasl

# Rate limiting
smtpd_client_connection_rate_limit = 30
smtpd_client_message_rate_limit = 60
smtpd_client_auth_rate_limit = 10
anvil_rate_time_unit = 60s

POSTFIX_SASL
    fi
    
    # Relay
    if [ "$ENABLE_RELAY" = "y" ]; then
        cat >> "$main_cf" << EOF
# ============================================================
# Relay Configuration
# ============================================================
relayhost = [${RELAY_HOST}]:${RELAY_PORT}
smtp_sasl_auth_enable = yes
smtp_sasl_password_maps = hash:/etc/postfix/sasl_passwd
smtp_sasl_security_options = noanonymous
smtp_sasl_tls_security_options = noanonymous
smtp_use_tls = yes
EOF
    fi
    
    # DKIM
    if [ "$ENABLE_DKIM" = "y" ]; then
        cat >> "$main_cf" << 'POSTFIX_DKIM'
# ============================================================
# DKIM Configuration (via OpenDKIM milter)
# ============================================================
milter_default_action = accept
milter_protocol = 6
smtpd_milters = local:/var/spool/postfix/var/run/opendkim/opendkim.sock
non_smtpd_milters = local:/var/spool/postfix/var/run/opendkim/opendkim.sock

POSTFIX_DKIM
    fi
    
    # Logging
    cat >> "$main_cf" << 'POSTFIX_LOG'
# ============================================================
# Logging
# ============================================================
maillog_file = /var/log/mail.log

# ============================================================
# Additional Security
# ============================================================
disable_vrfy_command = yes
smtpd_helo_required = yes
smtpd_helo_restrictions =
    permit_mynetworks,
    reject_invalid_helo_hostname,
    reject_non_fqdn_helo_hostname

smtpd_sender_restrictions =
    permit_sasl_authenticated,
    permit_mynetworks,
    reject_non_fqdn_sender,
    reject_unknown_sender_domain

smtpd_data_restrictions =
    reject_unauth_pipelining,
    reject_multi_recipient_bounce
POSTFIX_LOG
    
    log_success "Postfix main.cf generated"
    
    # Generate master.cf
    cat > "$master_cf" << 'POSTFIX_MASTER'
#
# Postfix master process configuration file.
# Generated by install.sh
#
# ==========================================================================
# service type  private unpriv  chroot  wakeup  maxproc command + args
# ==========================================================================

# SMTP Submission (port 587) - with SASL and TLS
submission inet n       -       n       -       -       smtpd
  -o syslog_name=postfix/submission
  -o smtpd_tls_security_level=encrypt
  -o smtpd_sasl_auth_enable=yes
  -o smtpd_sasl_type=cyrus
  -o smtpd_sasl_path=smtpd
  -o smtpd_recipient_restrictions=permit_sasl_authenticated,reject
  -o milter_macro_daemon_name=ORIGINATING
  -o smtpd_client_connection_count_limit=20
  -o smtpd_client_connection_rate_limit=30
  -o receive_override_options=no_unknown_recipient_checks,no_header_body_checks
  -o smtpd_helo_restrictions=
  -o smtpd_client_restrictions=
  -o smtpd_sender_restrictions=
  -o smtpd_recipient_restrictions=permit_sasl_authenticated,reject
  -o smtpd_end_of_data_restrictions=

# Internal / local delivery
local     unix  -       n       n       -       -       local
  -o syslog_name=postfix/local

virtual   unix  -       n       n       -       -       virtual

# Default SMTP transport (outbound delivery)
smtp      unix  -       -       y       -       -       smtp

# Relay through upstream
relay     unix  -       -       n       -       -       smtp
  -o syslog_name=postfix/relay
  -o smtp_helo_timeout=5
  -o smtp_connect_timeout=5

# Outbound connection pool
scache    unix  -       -       n       -       1       scache

# Pickup daemon
pickup    unix  n       -       n       60      1       pickup
  -o content_filter=
  -o receive_override_options=no_header_body_checks

# Cleanup daemon
cleanup   unix  n       -       n       -       0       cleanup
  -o internal_mail_filter_classes=reject_unauth_destination

# Queue manager
qmgr      unix  n       -       n       300     1       qmgr

# Bounce daemon
bounce    unix  -       -       n       -       0       bounce

# Deferred bounce
defer     unix  -       -       n       -       0       bounce

# Trace
trace     unix  -       -       n       -       0       bounce

# Verify
verify    unix  -       -       n       -       1       verify

# Flush
flush     unix  n       -       n       1000    0       flush

# Rewrite
rewrite   unix  -       -       n       -       -       trivial-rewrite

# Requeue
requeue   unix  -       -       n       -       -       smtp
  -o syslog_name=postfix/requeue

# Error
error     unix  -       -       n       -       -       error

# Discard
discard   unix  -       -       n       -       -       discard

# Anvil
anvil     unix  -       -       n       -       1       anvil

# Retry
retry     unix  -       -       n       -       -       error

# Proxymap
proxymap  unix  -       -       n       -       -       proxymap

# Proxywrite
proxywrite unix -       -       n       -       1       proxymap
  -o syslog_name=postfix/proxywrite

# Tuning
tlsmgr    unix  -       -       n       1000?   1       tlsmgr
  -o syslog_name=postfix/tlsmgr

# Postlog for Postfix logging
postlog   unix-dgram n  -       n       -       1       postlogd
POSTFIX_MASTER
    
    log_success "Postfix master.cf generated"
    
    # Generate relay password file if enabled
    if [ "$ENABLE_RELAY" = "y" ]; then
        local sasl_passwd="/etc/postfix/sasl_passwd"
        cat > "configs/postfix/sasl_passwd" << EOF
[${RELAY_HOST}]:${RELAY_PORT}	${RELAY_USERNAME}:${RELAY_PASSWORD}
EOF
        log_success "Relay password file generated"
    fi
}

generate_sasl_config() {
    header "Generating Cyrus SASL Configuration"
    
    mkdir -p configs/postfix/sasl
    
    cat > "configs/postfix/sasl/smtpd.conf" << 'SASLCONF'
#
# Postfix SMTP AUTH - Cyrus SASL configuration
# Generated by install.sh
#
pwcheck_method: saslauthd
mech_list: LOGIN PLAIN
saslauthd_path: /var/run/saslauthd/mux
log_level: 1
SASLCONF
    
    log_success "Cyrus SASL configuration generated"
    
    # Configure PAM
    mkdir -p configs/pam
    cat > "configs/pam/smtp" << 'PAMCONF'
#
# PAM configuration for SMTP SASL authentication
# Uses local system accounts with nologin shell
# Users must be in the 'smtpusers' group
#
auth    required    pam_unix.so    nullok_secure
account required    pam_unix.so
PAMCONF
    
    log_success "PAM service configuration generated"
}

generate_opendkim_config() {
    header "Generating OpenDKIM Configuration"
    
    mkdir -p configs/opendkim
    
    cat > "configs/opendkim/opendkim.conf" << 'OPENDKIM_CONF'
# ============================================================
# OpenDKIM Configuration
# Generated by install.sh
# ============================================================

# Run as opendkim user/group
AutoRestart              Yes
AutoRestartRate          10/1h
UMask                   007
Syslog                  yes
SyslogSuccess           Yes
LogWhy                  Yes

# Mode: filter (inbound milter) or signer (outbound)
Mode                    sv

# PID file
PidFile                 /var/run/opendkim/opendkim.pid

# Socket
Socket                  local:/var/spool/postfix/var/run/opendkim/opendkim.sock

# User and group
UserID                  opendkim:opendkim

# Key table
KeyTable                file:/etc/opendkim/KeyTable

# Signing table
SigningTable             file:/etc/opendkim/SigningTable

# Trusted hosts
InternalHosts           /etc/opendkim/TrustedHosts

# Canonicalization
Canonicalization        relaxed/simple

# Signature algorithm
SignatureAlgorithm      rsa-sha256

# Oversign Headers
OversignHeaders         From

# Minimum key size
MinimumKeyBits          1024

OPENDKIM_CONF
    
    log_success "OpenDKIM configuration generated"
    
    if [ "$ENABLE_DKIM" = "y" ]; then
        # TrustedHosts
        cat > "configs/opendkim/TrustedHosts" << EOF
127.0.0.1
::1
localhost
${DOMAIN}
${HOSTNAME}
EOF
        
        # KeyTable
        cat > "configs/opendkim/KeyTable" << EOF
${DKIM_SELECTOR}._domainkey.${DKIM_DOMAIN}:${DKIM_DOMAIN}:${DKIM_SELECTOR}:/etc/opendkim/keys/${DKIM_DOMAIN}/${DKIM_SELECTOR}.private
EOF
        
        # SigningTable
        cat > "configs/opendkim/SigningTable" << EOF
*@${DKIM_DOMAIN} ${DKIM_SELECTOR}._domainkey.${DKIM_DOMAIN}
EOF
        
        log_success "OpenDKIM tables generated"
    fi
}

# ============================================================
# Generate certificates
# ============================================================
generate_certificates() {
    header "Generating TLS Certificates"
    
    mkdir -p data/certs
    
    case "$TLS_TYPE" in
        self-signed)
            log_info "Generating self-signed certificate for ${DOMAIN}..."
            
            # Generate CA
            openssl genrsa -out "data/certs/ca.key" 4096 2>/dev/null
            openssl req -x509 -new -nodes \
                -key "data/certs/ca.key" \
                -sha256 -days 3650 \
                -out "data/certs/ca.crt" \
                -subj "/C=US/ST=Local/L=Local/O=SMTP-Relay-CA/CN=SMTP-Relay-CA" 2>/dev/null
            
            # Generate server key
            openssl genrsa -out "data/certs/mail.key" 2048 2>/dev/null
            
            # Generate CSR
            openssl req -new \
                -key "data/certs/mail.key" \
                -out "data/certs/mail.csr" \
                -subj "/C=US/ST=Local/L=Local/O=SMTP-Relay/CN=${DOMAIN}" 2>/dev/null
            
            # Create SAN extension
            cat > "data/certs/san.cnf" << EOF
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
DNS.4 = ${HOSTNAME}
IP.1 = 127.0.0.1
EOF
            
            # Sign certificate
            openssl x509 -req \
                -in "data/certs/mail.csr" \
                -CA "data/certs/ca.crt" \
                -CAkey "data/certs/ca.key" \
                -CAcreateserial \
                -out "data/certs/mail.crt" \
                -days 3650 -sha256 \
                -extensions v3_req \
                -extfile "data/certs/san.cnf" 2>/dev/null
            
            # Cleanup temp files
            rm -f "data/certs/mail.csr" "data/certs/san.cnf" "data/certs/ca.srl"
            
            # Set permissions
            chmod 600 "data/certs/mail.key" "data/certs/ca.key"
            chmod 644 "data/certs/mail.crt" "data/certs/ca.crt"
            
            log_success "Self-signed certificate generated"
            ;;
            
        existing)
            cp "$TLS_CERT_PATH" "data/certs/mail.crt"
            cp "$TLS_KEY_PATH" "data/certs/mail.key"
            chmod 600 "data/certs/mail.key"
            chmod 644 "data/certs/mail.crt"
            log_success "Existing certificate copied to data/certs/"
            ;;
            
        letsencrypt)
            # Will be mounted at runtime
            log_info "Let's Encrypt certificate will be mounted at runtime"
            ;;
    esac
}

# ============================================================
# Generate DKIM keys
# ============================================================
generate_dkim_keys() {
    header "Generating DKIM Keys"
    
    if [ "$ENABLE_DKIM" != "y" ]; then
        log_info "DKIM is disabled, skipping key generation"
        return 0
    fi
    
    mkdir -p "data/dkim/${DKIM_DOMAIN}"
    
    # Generate key with opendkim-genkey
    if command -v opendkim-genkey &> /dev/null; then
        opendkim-genkey \
            -b "$DKIM_KEY_SIZE" \
            -d "$DKIM_DOMAIN" \
            -D "data/dkim/${DKIM_DOMAIN}" \
            -s "$DKIM_SELECTOR" \
            -v 2>/dev/null || true
    else
        # Generate with openssl
        openssl genrsa -out "data/dkim/${DKIM_DOMAIN}/${DKIM_SELECTOR}.private" "$DKIM_KEY_SIZE" 2>/dev/null
        openssl rsa -in "data/dkim/${DKIM_DOMAIN}/${DKIM_SELECTOR}.private" \
            -pubout -out "data/dkim/${DKIM_DOMAIN}/${DKIM_SELECTOR}.public" 2>/dev/null
    fi
    
    # Set permissions
    chmod 600 "data/dkim/${DKIM_DOMAIN}/${DKIM_SELECTOR}.private"
    
    log_success "DKIM keys generated"
    
    # Display DNS record
    echo ""
    echo -e "${BOLD}${GREEN}============================================================${NC}"
    echo -e "${BOLD}${GREEN}  DKIM DNS Record for ${DKIM_DOMAIN}${NC}"
    echo -e "${BOLD}${GREEN}============================================================${NC}"
    echo ""
    echo "Add this TXT record to your DNS:"
    echo ""
    echo -e "  ${BOLD}Name:${NC}  ${DKIM_SELECTOR}._domainkey.${DKIM_DOMAIN}"
    echo -e "  ${BOLD}Type:${NC}  TXT"
    echo ""
    
    if [ -f "data/dkim/${DKIM_DOMAIN}/${DKIM_SELECTOR}.txt" ]; then
        echo "  ${BOLD}Value:${NC}"
        cat "data/dkim/${DKIM_DOMAIN}/${DKIM_SELECTOR}.txt"
    elif [ -f "data/dkim/${DKIM_DOMAIN}/${DKIM_SELECTOR}.public" ]; then
        PUBLIC_KEY=$(cat "data/dkim/${DKIM_DOMAIN}/${DKIM_SELECTOR}.public" | \
            sed -n '/-----BEGIN PUBLIC KEY-----/,/-----END PUBLIC KEY-----/p' | \
            grep -v "PUBLIC KEY" | tr -d '\n')
        echo "  ${BOLD}Value:${NC}"
        echo "  \"v=DKIM1; k=rsa; p=${PUBLIC_KEY}\""
    fi
    
    echo ""
    echo -e "${BOLD}${GREEN}============================================================${NC}"
    echo ""
}

# ============================================================
# Setup SASL users
# ============================================================
setup_sasl_users() {
    header "Setting Up SASL Users"
    
    if [ "$ENABLE_AUTH" != "y" ] || [ ${#USERS[@]} -eq 0 ]; then
        log_info "No SASL users to configure"
        return 0
    fi
    
    mkdir -p data/users
    
    # Create users file for persistent storage (plaintext: hashing is done inside container)
    > "data/users/smtp-users"
    
    for user_entry in "${USERS[@]}"; do
        local username="${user_entry%%:*}"
        local password="${user_entry#*:}"
        
        # Store plaintext password - the container will hash it with compatible crypt lib
        echo "${username}:${password}" >> "data/users/smtp-users"
        log_success "User '${username}' added to SMTP users database"
    done
    
    chmod 600 "data/users/smtp-users"
    
    log_success "SMTP users configured: $(wc -l < data/users/smtp-users)"
    log_info "Users will be created as system accounts (nologin shell) at container start"
}

# ============================================================
# Generate docker-compose.yml
# ============================================================
generate_docker_compose() {
    header "Generating Docker Compose Configuration"
    
    cat > docker-compose.yml << EOF
services:
  smtp:
    build: .
    container_name: smtp-relay
    restart: unless-stopped
    hostname: ${HOSTNAME}
    domainname: ${DOMAIN}
    ports:
      - "587:587"
    volumes:
      - ./data/dkim:/data/dkim
      - ./data/certs:/data/certs
      - ./data/users:/data/users
      - ./configs/postfix/main.cf:/etc/postfix/main.cf
      - ./configs/postfix/master.cf:/etc/postfix/master.cf
      - ./configs/postfix/sasl/smtpd.conf:/etc/postfix/sasl/smtpd.conf
      - ./configs/opendkim:/etc/opendkim
      - ./configs/pam/smtp:/etc/pam.d/smtp
    environment:
      - TZ=UTC
    healthcheck:
      test: ["CMD", "/usr/local/bin/healthcheck.sh"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s
    sysctls:
      - net.ipv4.ip_local_port_range=1024 65535
EOF
    
    # Add relay password file mount if enabled
    if [ "$ENABLE_RELAY" = "y" ]; then
        sed -i 's|      - ./configs/opendkim:/etc/opendkim:ro|      - ./configs/opendkim:/etc/opendkim:ro\n      - ./configs/postfix/sasl_passwd:/etc/postfix/sasl_passwd:ro|' docker-compose.yml
    fi
    
    # Add Let's Encrypt mount if needed
    if [ "$TLS_TYPE" = "letsencrypt" ]; then
        cat >> docker-compose.yml << 'COMPOSE_LE'
    volumes:
      - /etc/letsencrypt:/etc/letsencrypt:ro
COMPOSE_LE
    fi
    
    log_success "docker-compose.yml generated"
}

# ============================================================
# Generate deployment summary
# ============================================================
print_summary() {
    header "Installation Complete!"
    
    echo -e "${BOLD}Configuration Summary${NC}"
    echo "===================="
    echo ""
    echo "  ${BOLD}Hostname:${NC}       ${HOSTNAME}"
    echo "  ${BOLD}Domain:${NC}         ${DOMAIN}"
    echo "  ${BOLD}Port:${NC}           587 (SMTP Submission)"
    echo ""
    echo "  ${BOLD}Authentication:${NC} $([ "$ENABLE_AUTH" = "y" ] && echo "Enabled (${#USERS[@]} users)" || echo "Disabled")"
    echo "  ${BOLD}Relay:${NC}          $([ "$ENABLE_RELAY" = "y" ] && echo "Enabled (${RELAY_HOST}:${RELAY_PORT})" || echo "Direct delivery")"
    echo "  ${BOLD}DKIM:${NC}           $([ "$ENABLE_DKIM" = "y" ] && echo "Enabled (selector: ${DKIM_SELECTOR})" || echo "Disabled")"
    echo "  ${BOLD}TLS:${NC}            ${TLS_TYPE}"
    echo ""
    
    echo -e "${BOLD}Files Generated${NC}"
    echo "================"
    echo "  configs/postfix/main.cf"
    echo "  configs/postfix/master.cf"
    echo "  configs/postfix/sasl/smtpd.conf"
    echo "  configs/pam/smtp"
    echo "  configs/opendkim/opendkim.conf"
    echo "  configs/opendkim/TrustedHosts"
    echo "  configs/opendkim/KeyTable"
    echo "  configs/opendkim/SigningTable"
    echo "  docker-compose.yml"
    echo "  data/certs/mail.crt"
    echo "  data/certs/mail.key"
    [ "$ENABLE_DKIM" = "y" ] && echo "  data/dkim/${DKIM_DOMAIN}/${DKIM_SELECTOR}.private"
    [ "$ENABLE_AUTH" = "y" ] && echo "  data/users/smtp-users"
    echo ""
    
    echo -e "${BOLD}Deployment Steps${NC}"
    echo "=================="
    echo ""
    echo "  1. Build and start the container:"
    echo ""
    echo "     docker compose up -d --build"
    echo ""
    echo "  2. Check container status:"
    echo ""
    echo "     docker compose logs -f"
    echo ""
    echo "  3. Test SMTP connection:"
    echo ""
    echo "     openssl s_client -starttls smtp -connect localhost:587"
    echo ""
    
    if [ "$ENABLE_AUTH" = "y" ]; then
        echo "  4. Test SMTP authentication:"
        echo ""
        echo "     swaks --to recipient@example.com \\"
        echo "           --from sender@${DOMAIN} \\"
        echo "           --server localhost:587 \\"
        echo "           --auth LOGIN \\"
        echo "           --auth-user ${USERS[0]%%:*} \\"
        echo "           --auth-password <password>"
        echo ""
    fi
    
    if [ "$ENABLE_DKIM" = "y" ]; then
        echo -e "${BOLD}Important:${NC} Add the DKIM TXT record to your DNS:"
        echo ""
        echo "  ${DKIM_SELECTOR}._domainkey.${DKIM_DOMAIN}"
        echo ""
    fi
    
    echo -e "${BOLD}DNS Records Required${NC}"
    echo "======================"
    echo ""
    echo "  1. A record:  ${HOSTNAME} -> <server IP>"
    echo "  2. MX record:  ${DOMAIN} -> ${HOSTNAME} (priority 10)"
    echo "  3. TXT record: v=spf1 mx a ~all"
    
    if [ "$ENABLE_DKIM" = "y" ]; then
        echo "  4. DKIM TXT record (see above)"
    fi
    
    if [ "$ENABLE_DKIM" = "y" ]; then
        echo ""
        echo -e "${BOLD}DKIM DNS Record${NC}"
        echo "================"
        echo ""
        echo "  Name:  ${DKIM_SELECTOR}._domainkey.${DKIM_DOMAIN}"
        echo "  Type:  TXT"
        
        if [ -f "data/dkim/${DKIM_DOMAIN}/${DKIM_SELECTOR}.txt" ]; then
            echo "  Value: $(cat data/dkim/${DKIM_DOMAIN}/${DKIM_SELECTOR}.txt)"
        fi
    fi
    
    echo ""
    echo -e "${BOLD}${GREEN}SMTP Relay is ready to deploy!${NC}"
    echo ""
}

# ============================================================
# Main installation flow
# ============================================================
main() {
    echo ""
    echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}║       SMTP Relay - Interactive Installer         ║${NC}"
    echo -e "${BOLD}${CYAN}║  Postfix + Cyrus SASL (PAM) + OpenDKIM + TLS     ║${NC}"
    echo -e "${BOLD}${CYAN}║          Compiled by Kenn Arion Wong             ║${NC}"
    echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════╝${NC}"
    echo ""
    
    check_prerequisites
    collect_general_config
    collect_auth_config
    collect_relay_config
    collect_dkim_config
    collect_tls_config
    
    echo ""
    log_info "Generating configuration files..."
    
    generate_postfix_config
    generate_sasl_config
    generate_opendkim_config
    generate_certificates
    generate_dkim_keys
    setup_sasl_users
    generate_docker_compose
    
    print_summary
}

# Run main function
main "$@"