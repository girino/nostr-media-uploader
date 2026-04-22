# Build stage: Build nak using Go 1.26, Debian bookworm (glibc) for consistency with runtime image
FROM golang:1.26-bookworm AS nak-builder

WORKDIR /build

RUN apt-get update && apt-get upgrade -y --no-install-recommends && \
    rm -rf /var/lib/apt/lists/*

# Build nak from source
RUN go install github.com/fiatjaf/nak@latest

# Final stage: Python runtime with all dependencies (bookworm + full apt upgrade)
FROM python:3.12-slim-bookworm

# Set working directory
WORKDIR /app

# Install system dependencies required by nostr_media_uploader.sh
RUN apt-get update && apt-get upgrade -y --no-install-recommends && \
    apt-get install -y --no-install-recommends \
    bash \
    curl \
    unzip \
    ffmpeg \
    jq \
    file \
    coreutils \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Install Deno for yt-dlp JavaScript challenge solving support
RUN curl -fsSL https://deno.land/install.sh | sh -s -- --no-modify-path && \
    ln -sf /root/.deno/bin/deno /usr/local/bin/deno

# Install Python dependencies for telegram bot
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Install Python dependencies for nostr_media_uploader.sh
# gallery-dl requires >= 1.30.6 for Facebook support
# yt-dlp + yt-dlp-ejs: external JavaScript solver (EJS) for YouTube challenges; needs a JS runtime (Deno above)
# https://github.com/yt-dlp/yt-dlp/wiki/EJS
RUN pip install --no-cache-dir \
    gallery-dl==1.30.6 \
    yt-dlp \
    yt-dlp-ejs

# Copy nak binary from build stage
COPY --from=nak-builder /go/bin/nak /usr/local/bin/nak
RUN chmod +x /usr/local/bin/nak

# Copy telegram bot script
COPY telegram_bot.py .

# Copy nostr_media_uploader.sh and make it executable
COPY nostr_media_uploader.sh .
RUN chmod +x nostr_media_uploader.sh

# Copy other scripts that might be needed
COPY image_uploader.sh .
COPY aiart.sh .
RUN chmod +x image_uploader.sh aiart.sh

# Auto-NSFW: same interpreter as bot (requirements.txt); run_nude_detector uses system python when env is set
COPY run_nude_detector.sh nude_detector.py ./
RUN chmod +x run_nude_detector.sh
ENV RUN_NUDE_DETECTOR_USE_SYSTEM_PYTHON=1
# Fetch EJS challenge scripts from GitHub at runtime (override with ejs:npm if you prefer Deno/npm; unset to use wheel-only)
ENV YT_DLP_REMOTE_COMPONENTS=ejs:github

# Create directory for .nostr configs (will be mounted)
RUN mkdir -p /root/.nostr

# Verify installations
RUN gallery-dl --version && \
    yt-dlp --version && \
    pip show yt-dlp-ejs >/dev/null && \
    deno --version && \
    ffmpeg -version | head -n 1 && \
    jq --version && \
    file --version | head -n 1 && \
    nak --version && \
    python -c "import nudenet" && \
    echo "All dependencies installed successfully"

# Set default command
CMD ["python", "telegram_bot.py"]

