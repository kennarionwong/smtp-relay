#!/bin/bash
# ============================================================
# SMTP Auth User Management Script
# Add/remove/list SMTP users using local system accounts
# Users have /usr/sbin/nologin shell (cannot login interactively)
# ============================================================

set -e

SCRIPT_NAME=$(basename "$0")
USERS_FILE="/data/users/smtp-users"
USER_HASH_DIR="/data/users"

usage() {
    cat << EOF
SMTP Auth User Management

Usage:
  $SCRIPT_NAME add <username> [password]
  $SCRIPT_NAME remove <username>
  $SCRIPT_NAME list
  $SCRIPT_NAME passwd <username> [password]
  $SCRIPT_NAME verify <username> <password>

Examples:
  $SCRIPT_NAME add alice
  $SCRIPT_NAME add bob mysecretpass
  $SCRIPT_NAME list
  $SCRIPT_NAME remove alice
  $SCRIPT_NAME passwd bob newpass
  $SCRIPT_NAME verify alice mypass

If no password is provided, you will be prompted.
EOF
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "ERROR: This command must be run as root"
        exit 1
    fi
}

get_password() {
    local username="$1"
    local password=""
    
    if [ -n "$2" ]; then
        echo "$2"
        return
    fi
    
    read -srp "Enter password for $username: " password
    echo ""
    
    if [ -z "$password" ]; then
        echo "ERROR: Password cannot be empty"
        exit 1
    fi
    
    local confirm
    read -srp "Confirm password: " confirm
    echo ""
    
    if [ "$password" != "$confirm" ]; then
        echo "ERROR: Passwords do not match"
        exit 1
    fi
    
    echo "$password"
}

add_user() {
    local username="$1"
    local password
    local hash
    
    require_root
    
    if [ -z "$username" ]; then
        echo "ERROR: Username is required"
        exit 1
    fi
    
    # Check if user already exists
    if id "$username" &>/dev/null; then
        echo "User '$username' already exists."
        echo "Use '$SCRIPT_NAME passwd $username' to change password."
        exit 1
    fi
    
    password=$(get_password "$username" "$2")
    
    # Ensure smtpusers group exists
    getent group smtpusers > /dev/null 2>&1 || groupadd -r smtpusers
    
    # Create system user with nologin shell and smtpusers group
    useradd -M -s /usr/sbin/nologin -d "/home/$username" -G smtpusers "$username" 2>/dev/null
    echo "$password" | passwd --stdin "$username" 2>/dev/null || \
        echo "$username:$password" | chpasswd 2>/dev/null
    
    # Store plaintext password in persistent users file
    # (entrypoint.sh will hash it inside the container with compatible crypt lib)
    mkdir -p "$USER_HASH_DIR"
    if [ -f "$USERS_FILE" ]; then
        grep -v "^${username}:" "$USERS_FILE" > "${USERS_FILE}.tmp" 2>/dev/null || true
        mv "${USERS_FILE}.tmp" "$USERS_FILE" 2>/dev/null || true
    fi
    echo "${username}:${password}" >> "$USERS_FILE"
    chmod 600 "$USERS_FILE"
    
    echo "✓ User '$username' created (shell: /usr/sbin/nologin)"
    echo "  Credentials saved to $USERS_FILE"
}

remove_user() {
    local username="$1"
    
    require_root
    
    if [ -z "$username" ]; then
        echo "ERROR: Username is required"
        exit 1
    fi
    
    # Remove system user
    if id "$username" &>/dev/null; then
        userdel "$username" 2>/dev/null || true
        echo "✓ System user '$username' removed"
    else
        echo "System user '$username' not found"
    fi
    
    # Remove from persistent file
    if [ -f "$USERS_FILE" ]; then
        grep -v "^${username}:" "$USERS_FILE" > "${USERS_FILE}.tmp" 2>/dev/null || true
        mv "${USERS_FILE}.tmp" "$USERS_FILE" 2>/dev/null || true
        echo "✓ Removed '$username' from $USERS_FILE"
    fi
}

list_users() {
    require_root
    
    echo "SMTP Users:"
    echo "==========="
    
    # Show users from /etc/shadow with nologin shell
    while IFS=: read -r user pass rest; do
        shell=$(grep "^${user}:" /etc/passwd 2>/dev/null | cut -d: -f7 || echo "")
        if [ "$shell" = "/usr/sbin/nologin" ]; then
            if [ "$pass" = "!" ] || [ "$pass" = "*" ] || [ "$pass" = "!!" ]; then
                echo "  $user [LOCKED]"
            else
                last=$(grep "^${user}:" /etc/passwd 2>/dev/null | cut -d: -f5 || echo "")
                echo "  $user [active]"
            fi
        fi
    done < /etc/shadow 2>/dev/null || true
    
    # Show from persistent file
    if [ -f "$USERS_FILE" ]; then
        echo ""
        echo "Persistent storage: $USERS_FILE"
        while IFS=: read -r user hash uid gid; do
            if id "$user" &>/dev/null; then
                echo "  ✓ $user (active)"
            else
                echo "  ✗ $user (not created yet)"
            fi
        done < "$USERS_FILE"
    else
        echo ""
        echo "No persistent user file found at $USERS_FILE"
    fi
}

change_password() {
    local username="$1"
    local password
    
    require_root
    
    if [ -z "$username" ]; then
        echo "ERROR: Username is required"
        exit 1
    fi
    
    password=$(get_password "$username" "$2")
    
    # Update system password
    if id "$username" &>/dev/null; then
        echo "$password" | passwd --stdin "$username" 2>/dev/null || \
            echo "${username}:${password}" | chpasswd 2>/dev/null
        echo "✓ Password changed for system user '$username'"
    else
        echo "WARNING: System user '$username' doesn't exist yet"
        echo "  It will be created at container restart"
    fi
    
    # Update persistent file
    if [ -f "$USERS_FILE" ] || [ -d "$USER_HASH_DIR" ]; then
        mkdir -p "$USER_HASH_DIR"
        
        if [ -f "$USERS_FILE" ]; then
            grep -v "^${username}:" "$USERS_FILE" > "${USERS_FILE}.tmp" 2>/dev/null || true
            mv "${USERS_FILE}.tmp" "$USERS_FILE" 2>/dev/null || true
        fi
        echo "${username}:${password}" >> "$USERS_FILE"
        chmod 600 "$USERS_FILE"
        echo "✓ Credentials updated in $USERS_FILE"
    fi
}

verify_user() {
    local username="$1"
    local password="$2"
    
    if [ -z "$username" ] || [ -z "$password" ]; then
        echo "ERROR: Both username and password are required for verification"
        exit 1
    fi
    
    if ! id "$username" &>/dev/null; then
        echo "✗ User '$username' does not exist"
        exit 1
    fi
    
    # Test via saslauthd
    if command -v testsaslauthd &>/dev/null; then
        testsaslauthd -u "$username" -p "$password" -f /var/run/saslauthd/mux -r smtp
        local result=$?
        if [ $result -eq 0 ]; then
            echo "✓ SASL authentication successful for '$username'"
        else
            echo "✗ SASL authentication FAILED for '$username'"
        fi
        exit $result
    else
        # Fallback: test via PAM directly
        if command -v python3 &>/dev/null; then
            python3 -c "
import subprocess, sys
try:
    p = subprocess.Popen(['/usr/sbin/saslauthd', '-a', 'pam'], 
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    p.terminate()
except: pass
print('testsaslauthd not available. Install with: apt-get install sasl2-bin')
sys.exit(1)
"
        else
            echo "testsaslauthd not available."
            echo "Install with: apt-get install sasl2-bin"
            echo ""
            echo "Quick test: try SMTP AUTH with openssl:"
            echo "  printf 'AUTH LOGIN\\r\\n' | openssl s_client -starttls smtp -connect localhost:587"
        fi
    fi
}

# Main
case "${1:-}" in
    add)
        add_user "$2" "$3"
        ;;
    remove|rm|delete)
        remove_user "$2"
        ;;
    list|ls)
        list_users
        ;;
    passwd|password|set)
        change_password "$2" "$3"
        ;;
    verify|test|check)
        verify_user "$2" "$3"
        ;;
    *)
        usage
        ;;
esac