#!/bin/bash
# ============================================================
# SMTP Relay Health Check Script
# Verifies Postfix, saslauthd, and OpenDKIM are running
# ============================================================

# Check Postfix
if ! pgrep -x master > /dev/null 2>&1; then
    echo "HEALTHCHECK: Postfix (master) is NOT running"
    exit 1
fi

# Check saslauthd
if ! pgrep -x saslauthd > /dev/null 2>&1; then
    echo "HEALTHCHECK: saslauthd is NOT running"
    exit 1
fi

# Check OpenDKIM
if ! pgrep -x opendkim > /dev/null 2>&1; then
    echo "HEALTHCHECK: OpenDKIM is NOT running"
    exit 1
fi

# Check TLS certificates
if [ ! -f "/data/certs/mail.crt" ] || [ ! -f "/data/certs/mail.key" ]; then
    echo "HEALTHCHECK: TLS certificates missing"
    exit 1
fi

# Quick SMTP test - check Postfix is listening on 587
if command -v ss &>/dev/null; then
    if ! ss -tlnp | grep -q ":587 "; then
        echo "HEALTHCHECK: Postfix not listening on port 587"
        exit 1
    fi
elif command -v netstat &>/dev/null; then
    if ! netstat -tlnp 2>/dev/null | grep -q ":587 "; then
        echo "HEALTHCHECK: Postfix not listening on port 587"
        exit 1
    fi
fi

echo "HEALTHCHECK: All services healthy"
exit 0