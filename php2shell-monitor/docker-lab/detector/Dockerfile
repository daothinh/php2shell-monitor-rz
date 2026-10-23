# PHP2SHELL LAB - Simplified vulnerable target
# Uses PHP built-in server for simpler setup

FROM php:8.2.34-cli-bookworm

LABEL maintainer="php2shell-monitor-lab"
LABEL php_version="8.2.34"
LABEL vulnerability="CVE-2026-109618,CVE-2026-109619"

# Install basic tools
RUN apt-get update && apt-get install -y \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Configure PHP for vulnerability testing
RUN { \
    echo "memory_limit = 256M"; \
    echo "upload_max_filesize = 20M"; \
    echo "post_max_size = 20M"; \
    echo "session.upload_progress.enabled = On"; \
    echo "session.upload_progress.cleanup = On"; \
    echo "session.upload_progress.name = PHP_SESSION_UPLOAD_PROGRESS"; \
    echo "session.upload_progress.freq = 1%"; \
    echo "session.upload_progress.min_freq = 1"; \
    echo "log_errors = On"; \
    echo "error_log = /var/log/php/error.log"; \
    echo "error_reporting = E_ALL"; \
} > /usr/local/etc/php/conf.d/php2shell-lab.ini

# Create web root
RUN mkdir -p /var/www/html /var/log/php

# Simple test application
RUN { \
    echo "<?php"; \
    echo "phpinfo();"; \
    echo "?>"; \
} > /var/www/html/index.php

# Upload endpoint (vulnerable)
RUN { \
    echo "<?php"; \
    echo "// CVE-2026-109618/109619 test endpoint"; \
    echo "error_log('[PHP2SHELL-TEST] Request to upload.php: ' . json_encode([\$_GET, \$_POST, \$_FILES, \$_COOKIE]));"; \
    echo "if (\$_FILES) {"; \
    echo "    error_log('[PHP2SHELL-TEST] File upload detected');"; \
    echo "}"; \
    echo "echo json_encode(['status' => 'ok', 'php_version' => PHP_VERSION]);"; \
    echo "?>"; \
} > /var/www/html/upload.php

WORKDIR /var/www/html

# Expose port
EXPOSE 8000

# Start PHP built-in server with access log to stdout
CMD ["php", "-S", "0.0.0.0:8000", "-t", "/var/www/html"]
