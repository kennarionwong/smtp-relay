FROM debian:latest

LABEL maintainer="smtp-relay" \
      description="Production-ready SMTP relay with Postfix, Cyrus SASL (PAM), and OpenDKIM"

# Prevent interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Install required packages
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        postfix \
        opendkim \
        opendkim-tools \
        sasl2-bin \
        libsasl2-modules \
        libpam-modules \
        rsyslog \
        ca-certificates \
        openssl \
        whois \
        mailutils \
        bash \
        curl \
        dnsutils \
        procps \
        logrotate && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Create required directories
RUN mkdir -p /etc/postfix/dynamicmaps.cf.d && \
    mkdir -p /var/spool/postfix/var/run/opendkim && \
    mkdir -p /etc/opendkim/keys && \
    mkdir -p /var/run/opendkim && \
    mkdir -p /var/run/saslauthd && \
    mkdir -p /var/spool/postfix/var/run/saslauthd && \
    mkdir -p /var/log/mail && \
    mkdir -p /data/dkim && \
    mkdir -p /data/certs && \
    mkdir -p /data/users

# Copy configuration templates
COPY configs/postfix/ /etc/postfix/
COPY configs/opendkim/ /etc/opendkim/

# Copy scripts
COPY scripts/ /usr/local/bin/
COPY entrypoint.sh /entrypoint.sh

# Make scripts executable
RUN chmod +x /entrypoint.sh && \
    chmod +x /usr/local/bin/*.sh 2>/dev/null || true

# OpenDKIM socket directory
RUN chown opendkim:opendkim /var/spool/postfix/var/run/opendkim && \
    chmod 750 /var/spool/postfix/var/run/opendkim

# Set proper permissions
RUN chown -R opendkim:opendkim /etc/opendkim && \
    chmod 700 /etc/opendkim/keys

# Create saslauthd system user if not exists
RUN useradd -r -s /usr/sbin/nologin -M saslauthd 2>/dev/null || true

# Create smtpusers group for SMTP authentication
RUN groupadd -r smtpusers 2>/dev/null || true

# Add postfix user to opendkim group so Postfix can access the DKIM socket
RUN usermod -aG opendkim postfix 2>/dev/null || true

# Configure rsyslog to log to stdout
RUN echo '# Mail logging to stdout' > /etc/rsyslog.d/50-default.conf && \
    echo '*.* /dev/stdout' >> /etc/rsyslog.d/50-default.conf

# Configure saslauthd defaults
RUN printf 'START=yes\nDESC="SASL Authentication Daemon"\nNAME="saslauthd"\nMECHANISMS="pam"\nMECH_OPTIONS=""\nTHREADS=5\nOPTIONS="-c -m /var/run/saslauthd"\n' > /etc/default/saslauthd

# Expose submission port
EXPOSE 587

# Healthcheck
HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
    CMD /usr/local/bin/healthcheck.sh

# Entrypoint
ENTRYPOINT ["/entrypoint.sh"]