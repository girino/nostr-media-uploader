# Nostr Media Uploader

A powerful command-line tool for downloading media (images and videos) from social media platforms and publishing them to Nostr. Automatically handles video codec conversion, supports multiple Nostr blossom servers, and provides robust error handling with intelligent fallback mechanisms.

## Disclaimer

**This project was created for personal use and is published only so that others with similar needs can copy and adapt the code for their own purposes.**

The code will be updated according to my personal needs and priorities. **No feature requests or suggestions are accepted.** This is not a collaborative project - it is a personal tool that happens to be publicly available for reference and adaptation.

If you find this code useful, feel free to:
- Fork it and modify it for your own needs
- Copy and adapt portions of it
- Learn from it

If you need different functionality or have questions, please adapt the code yourself rather than requesting changes.

## Features

### Media Download & Processing
- **Download from URLs**: Automatically downloads images and videos from social media URLs (Facebook, Instagram, etc.)
- **Local File Support**: Process local image/video files directly
- **Multiple Sources**: Supports multiple URLs or files in a single command
- **Metadata Extraction**: Automatically extracts captions and metadata from downloaded content

### Video Processing
- **Intelligent Codec Conversion**: Automatically converts incompatible video codecs (e.g., AV1) to iOS-compatible formats (H.264/H.265)
- **Hardware Acceleration**: Prioritizes hardware-accelerated encoding (QSV, NVENC, AMF) when available
- **Software Fallback**: Falls back to software encoders (libx264, libx265) if hardware encoding fails
- **Smart Bitrate Adjustment**: Automatically adjusts bitrate based on codec efficiency

### Nostr Integration
- **Multiple Blossom Servers**: Supports multiple Nostr blossom servers with automatic fallback
- **Event Publishing**: Creates and publishes Nostr kind 1 events with media URLs
- **Relay Support**: Configurable relay servers for event broadcasting
- **Proof of Work**: Optional proof-of-work support for event mining

### Cross-Platform Support
- **Linux Native**: Full support for native Linux systems
- **Cygwin Compatible**: Works seamlessly on Cygwin/Windows
- **OS Detection**: Automatic OS detection with platform-specific optimizations
- **Path Handling**: Smart path conversion for cross-platform compatibility

### Advanced Features
- **History Tracking**: Prevents duplicate uploads using SHA256 hash tracking
- **Gallery Support**: Handles multi-image galleries with intelligent caption placement
- **Facebook URL Processing**: Advanced Facebook URL handling with position inference
- **Cookie Support**: Optional Firefox cookie integration for authenticated downloads
- **Cookies File Support**: Use custom cookies files (Mozilla/Netscape format) for authenticated downloads
- **Error Recovery**: Robust error handling with automatic server fallback
- **Environment Configuration**: Flexible configuration via environment files or profiles

## Scripts

This repository contains three main scripts:

- **`nostr_media_uploader.sh`**: Main script for downloading and uploading media from URLs or local files
- **`image_uploader.sh`**: Specialized script for downloading and uploading images from URLs
- **`aiart.sh`**: Profile-based uploader for AI-generated art with hashtag support

## Documentation

- **[INSTALLATION.md](INSTALLATION.md)**: Detailed installation instructions for all platforms
- **[USAGE.md](USAGE.md)**: Comprehensive usage guide with examples
- **[CONTRIBUTING.md](CONTRIBUTING.md)**: Guidelines for contributing
- **[SECURITY.md](SECURITY.md)**: Security policy and best practices
- **[CHANGELOG.md](CHANGELOG.md)**: Version history and changes
- **[LICENSE](LICENSE)**: Girino's Anarchist License (GAL)
- **[example_env](example_env)**: Example configuration file template

## Quick Start

### Recommended: Docker (Simplest)

1. **Configure your Nostr keys**:
   ```bash
   cp example_env ~/.nostr/nostr_media_uploader
   # Edit ~/.nostr/nostr_media_uploader with your keys
   ```

2. **Extract cookies from Firefox** (optional, for authenticated downloads):
   ```bash
   python extract_firefox_cookies.py firefox_cookies.txt
   ```

3. **Start with Docker Compose**:
   ```bash
   docker-compose up -d
   ```

4. **View logs**:
   ```bash
   docker-compose logs -f
   ```

That's it! The Telegram bot is now running in Docker with all dependencies pre-installed.

**For manual script usage in Docker:**
```bash
# Run the script inside the container
docker-compose exec telegram-bot bash /app/nostr_media_uploader.sh https://web.facebook.com/reel/1234567890
```

### Alternative: Native Installation

If you prefer to run natively without Docker:

1. **Install dependencies** (see [INSTALLATION.md](INSTALLATION.md) for details):
   ```bash
   # Install gallery-dl (requires >= 1.30.6)
   pipx install gallery-dl==1.30.6
   
   # Install yt-dlp
   pipx install yt-dlp
   
   # Install system dependencies
   apt-get install ffmpeg jq file
   ```

2. **Configure your Nostr keys**:
   ```bash
   cp example_env ~/.nostr/nostr_media_uploader
   # Edit ~/.nostr/nostr_media_uploader with your keys
   ```

3. **Download and upload from URL**:
   ```bash
   ./nostr_media_uploader.sh https://web.facebook.com/reel/1234567890
   ```

4. **Upload local files**:
   ```bash
   ./nostr_media_uploader.sh video.mp4 image.jpg "My caption"
   ```

## Installation

For detailed installation instructions, see [INSTALLATION.md](INSTALLATION.md).

### Requirements

- `gallery-dl` (>= 1.30.6) - For downloading images from social media
- `yt-dlp` - For downloading videos from various platforms
- `ffmpeg` & `ffprobe` - For video processing and codec detection
- `jq` - For JSON processing
- `nak` - Nostr command-line tool
- `sha256sum` - For hash calculation
- `file` - For MIME type detection

### Optional Tools

- `blossom-cli` - Fallback upload tool (optional)
- Hardware-accelerated encoding support (Intel QSV, NVIDIA NVENC, AMD AMF)

## Usage

### Basic Usage

```bash
# Download and upload from URL
./nostr_media_uploader.sh https://web.facebook.com/reel/1174103824690243

# Upload local files with description
./nostr_media_uploader.sh video.mp4 image.jpg "Gallery description"

# Multiple URLs
./nostr_media_uploader.sh url1 url2 url3 "Description"
```

### Command-Line Options

- `--convert` / `--noconvert`: Enable/disable video conversion (default: enabled)
- `--norelay`: Don't send event to Nostr relays
- `--nopow`: Disable proof of work
- `--nocheck`: Disable hash check (allows re-uploading)
- `--comment` / `--nocomment`: Enable/disable original captions (default: enabled)
- `--firefox`: Use Firefox cookies for authenticated downloads
- `--cookies <file>`: Use cookies from specified file (Mozilla/Netscape format). Takes precedence over `--firefox`
- `--encoders <list>`: Comma-separated list of video encoders to use (e.g., `libx264,hevc_qsv`). Overrides automatic detection. Encoders will be tried in the specified order.
- `--source` / `--nosource`: Show/hide source URLs in posts
- `--password <password>`: Provide password for encrypted keys
- `--max-file-search <number>`: Maximum files to search when inferring Facebook image positions
- `-h`, `--help`: Show help message

### Examples

#### Video Upload with Firefox Cookies
```bash
./nostr_media_uploader.sh -firefox https://web.facebook.com/reel/1174103824690243
```

#### Video Upload with Cookies File
```bash
./nostr_media_uploader.sh --cookies firefox_cookies.txt https://web.facebook.com/reel/1174103824690243
```

#### Specify Video Encoders
```bash
# Use specific hardware encoders
./nostr_media_uploader.sh --encoders hevc_qsv,h264_qsv https://web.facebook.com/reel/1174103824690243

# Use software encoders only
./nostr_media_uploader.sh --encoders libx264,libx265 https://web.facebook.com/reel/1174103824690243
```

#### Upload Without Relay Broadcast
```bash
./nostr_media_uploader.sh --norelay video.mp4
```

#### Custom Source Attribution
```bash
./nostr_media_uploader.sh video.mp4 "Description" "https://source.example.com"
```

#### Disable Video Conversion
```bash
./nostr_media_uploader.sh --noconvert video.mp4
```

## Configuration

Configuration is done via environment variables in `~/.nostr/${SCRIPT_NAME%.*}`.

For `nostr_media_uploader.sh`, the config file is `~/.nostr/nostr_media_uploader`.

For `image_uploader.sh`, the config file is `~/.nostr/image_uploader`.

For `aiart.sh`, use profiles in `~/.nostr/` (default profile: "tarado").

### Using Multiple Profiles with Symlinks

To use different profiles with different Nostr keys, you can create symlinks of the script with different names. The script will automatically look for a configuration file based on the script name (without the `.sh` extension).

**Example: Creating a profile for "work" account**

```bash
# Create a symlink with a different name
ln -s nostr_media_uploader.sh work_uploader.sh

# Create the corresponding config file
cp example_env ~/.nostr/work_uploader

# Edit the config file with your work account keys
nano ~/.nostr/work_uploader

# Now use the symlink - it will use ~/.nostr/work_uploader config
./work_uploader.sh https://example.com/media
```

The script name determines which config file is loaded:
- `nostr_media_uploader.sh` → `~/.nostr/nostr_media_uploader`
- `work_uploader.sh` → `~/.nostr/work_uploader`
- `personal_uploader.sh` → `~/.nostr/personal_uploader`

This allows you to easily switch between different Nostr accounts or configurations by using different symlink names.

See [example_env](example_env) for a complete configuration template.

### Key Configuration Variables

- **`NSEC_KEY`**: Nostr secret key (nsec format) - recommended
- **`KEY`**: Encrypted private key (requires password)
- **`NCRYPT_KEY`**: Password-encrypted Nostr key
- **`PASSWORD`**: Password for encrypted keys (can be provided via command line)

### Optional Configuration

- **`EXTRA_RELAYS`**: Additional relay servers (array)
- **`EXTRA_BLOSSOMS`**: Additional blossom servers (array)
- **`DISPLAY_SOURCE`**: Show source URLs in posts (0/1, default: 0)
- **`POW_DIFF`**: Proof of work difficulty (default: 20)
- **`USE_COOKIES_FF`**: Use Firefox cookies by default (0/1, default: 0)
- **`COOKIES_FILE`**: Path to cookies file (Mozilla/Netscape format). If set, takes precedence over `USE_COOKIES_FF` and `--firefox` option
- **`ENCODERS`**: Comma-separated list of preferred video encoders (e.g., `libx264,hevc_qsv`). Overrides automatic encoder detection. Encoders will be tried in the specified order.
- **`APPEND_ORIGINAL_COMMENT`**: Append original captions (0/1, default: 1)

## Docker Deployment

Docker is the **recommended** way to run the Telegram bot, as it includes all dependencies and simplifies setup.

### Prerequisites

- Docker and Docker Compose installed
- Your Nostr keys configured in `~/.nostr/nostr_media_uploader`
- (Optional) Firefox cookies file for authenticated downloads

### Quick Setup

1. **Configure Nostr keys**:
   ```bash
   cp example_env ~/.nostr/nostr_media_uploader
   # Edit ~/.nostr/nostr_media_uploader with your keys
   ```

2. **Extract cookies** (optional):
   ```bash
   python extract_firefox_cookies.py firefox_cookies.txt
   ```

3. **Configure Telegram bot**:
   ```bash
   cp telegram_bot.yaml.example telegram_bot.yaml
   # Edit telegram_bot.yaml with your bot token and channel settings
   ```

4. **Start the container**:
   ```bash
   docker-compose up -d
   ```

5. **View logs**:
   ```bash
   docker-compose logs -f
   ```

### Docker Configuration

The `docker-compose.yml` file mounts:
- `~/.nostr` directory (read-only) - Contains your Nostr keys and configuration
- `firefox_cookies.txt` (read-write) - Cookies file for authenticated downloads
- `telegram_bot.yaml` (read-only) - Telegram bot configuration
- Scripts (read-only) - `nostr_media_uploader.sh`, `image_uploader.sh`, `aiart.sh`

### Hardware Acceleration (Optional)

For Intel Quick Sync Video (QSV) hardware acceleration, uncomment the devices section in `docker-compose.yml`:

```yaml
devices:
  - /dev/dri:/dev/dri  # Intel QSV on Linux
  # - /dev/dxg:/dev/dxg  # WSL2 uses dxg, not dri
```

### Running Scripts in Docker

To run the uploader script manually inside the container:

```bash
# Run with cookies file
docker-compose exec telegram-bot bash /app/nostr_media_uploader.sh --cookies /app/firefox_cookies.txt https://example.com/media

# Run with specific encoders
docker-compose exec telegram-bot bash /app/nostr_media_uploader.sh --encoders libx264,hevc_qsv https://example.com/media
```

### Updating

To update the Docker image with latest changes:

```bash
# Rebuild the image
docker-compose build

# Restart the container
docker-compose up -d
```

## Platform Support

- ✅ **Docker** (recommended) - Works on Linux, macOS, Windows (WSL2)
- ✅ Linux (native)
- ✅ Cygwin (Windows)
- ⚠️ macOS (may work but not tested)

## Video Codec Support

The script automatically handles video codec conversion with intelligent encoder selection:

### Encoder Priority

1. **Hardware-accelerated encoding** (if available):
   - H.265: Intel QSV (hevc_qsv), NVIDIA NVENC (hevc_nvenc), AMD AMF (hevc_amf), VideoToolbox (hevc_videotoolbox), V4L2 M2M (hevc_v4l2m2m)
   - H.264: Intel QSV (h264_qsv), NVIDIA NVENC (h264_nvenc), AMD AMF (h264_amf), VideoToolbox (h264_videotoolbox), V4L2 M2M (h264_v4l2m2m)

2. **Software encoding** (fallback):
   - H.264: libx264 (preferred - faster)
   - H.265: libx265 (better compression, slower)

The script automatically detects available hardware and selects the best encoder. Hardware encoders are tested with actual encoding to ensure they work (especially important in Docker/WSL2 environments).

### Custom Encoder Selection

You can override automatic detection by specifying encoders:

```bash
# Via command line
./nostr_media_uploader.sh --encoders libx264,hevc_qsv video.mp4

# Via environment variable (in config file)
ENCODERS="hevc_qsv,h264_qsv,libx264,libx265"
```

Encoders are tried in the order specified. If an encoder fails, the next one in the list is attempted.

## Error Handling

- Automatic fallback between multiple blossom servers
- Hardware encoder detection with software fallback
- Intelligent codec conversion with multiple encoder attempts
- Comprehensive error messages with troubleshooting hints
- History tracking to prevent duplicate uploads

## History Tracking

The script maintains a history file (`${SCRIPT_NAME%.*}.history`) in the script directory to prevent duplicate uploads. Hashes of processed files and URLs are stored to avoid re-processing.

To disable history checking, use the `--nocheck` option.

## Cookie Management

The script supports using cookies for authenticated downloads from social media platforms. You can use cookies in three ways:

### 1. Firefox Browser Cookies (Automatic)

Use the `--firefox` flag to automatically extract cookies from your Firefox browser:

```bash
./nostr_media_uploader.sh --firefox https://web.facebook.com/reel/1234567890
```

Or set `USE_COOKIES_FF=1` in your configuration file to enable by default.

### 2. Cookies File (Recommended)

You can extract cookies from Firefox and save them to a file for reuse. This is useful for:
- Sharing cookies across multiple scripts
- Using cookies without having Firefox running
- Better control over cookie management

**Extract cookies from Firefox:**

A Python script (`extract_firefox_cookies.py`) is provided to extract all cookies from Firefox:

```bash
# Extract cookies to default file (firefox_cookies.txt)
python extract_firefox_cookies.py

# Extract cookies to custom file
python extract_firefox_cookies.py my_cookies.txt
```

The script will:
- Automatically find your Firefox profile
- Extract all cookies from the cookies database
- Save them in Mozilla/Netscape cookie format

**Use cookies file:**

```bash
# Via command line
./nostr_media_uploader.sh --cookies firefox_cookies.txt https://example.com/media

# Via environment variable
export COOKIES_FILE=./firefox_cookies.txt
./nostr_media_uploader.sh https://example.com/media

# Via configuration file
# Add to ~/.nostr/nostr_media_uploader:
COOKIES_FILE="./firefox_cookies.txt"
```

**Priority order:**
1. Command line `--cookies` (highest priority)
2. Environment variable `COOKIES_FILE`
3. Configuration file `COOKIES_FILE`
4. Command line `--firefox`
5. Configuration file `USE_COOKIES_FF`

If `COOKIES_FILE` is set (via env var or config), the `--firefox` option will be ignored.

### 3. Cookie File Format

The cookies file must be in Mozilla/Netscape cookie format:

```
# Netscape HTTP Cookie File
# This is a generated file! Do not edit.

.domain.com	TRUE	/path	FALSE	1234567890	cookie_name	cookie_value
```

The format is: `domain`, `flag`, `path`, `secure`, `expiration`, `name`, `value` (tab-separated).

## Troubleshooting

### Video Conversion Fails

If video conversion fails:
1. Check that `ffmpeg` is installed with h264/h265 codec support
2. Verify hardware encoder availability (if using hardware acceleration)
3. Check `ffmpeg` error output for specific issues

### gallery-dl Version Too Old

The script requires `gallery-dl >= 1.30.6` for Facebook support:
```bash
# Check version
gallery-dl --version

# Upgrade on Linux
pipx install --force gallery-dl==1.30.6

# Upgrade on Cygwin
pip install --upgrade gallery-dl==1.30.6
```

### Missing Dependencies

The script will automatically check for required commands and provide installation instructions if any are missing.

## Contributing

This project does not accept contributions, feature requests, or suggestions. It is maintained for personal use only. If you need different functionality, please fork the repository and adapt it for your own needs.

## License

This project is licensed under **Girino's Anarchist License (GAL)**. See [LICENSE](LICENSE) for details.

## Links

- **License**: https://license.girino.org/GAL
- **Nostr**: https://nostr.com
- **gallery-dl**: https://github.com/mikf/gallery-dl
- **yt-dlp**: https://github.com/yt-dlp/yt-dlp
- **nak**: https://github.com/fiatjaf/nak

## Telegram Bot

The repository includes a Telegram bot (`telegram_bot.py`) that can automatically process links and media files posted in Telegram channels or groups and upload them using `nostr_media_uploader.sh`.

### Features

- **Multi-Channel Support**: Configure multiple channels, each with its own profile
- **Media File Processing**: Automatically downloads and processes photos, videos, and documents sent to the bot
- **URL Processing**: Extracts and processes URLs from messages
- **Configuration Reload**: Use `/reload` command in private chat to reload configuration without restarting
- **Firefox Cookie Support**: Optional `--firefox` flag support (can be disabled with `--no-firefox`)
- **Cookies File Support**: Use custom cookies files via `--cookies` option or `cookies_file` config setting
- **Cross-Platform**: Works on Linux, Cygwin/Windows, and macOS

### Setup

#### Recommended: Docker (Simplest)

1. **Create a Telegram bot**:
   - Talk to [@BotFather](https://t.me/BotFather) on Telegram
   - Use `/newbot` command to create a new bot
   - Save the bot token you receive

2. **Get your Telegram User ID**:
   - Talk to [@userinfobot](https://t.me/userinfobot) to get your user ID

3. **Get Chat ID** (for channels/groups):
   - For channels: Use [@getidsbot](https://t.me/getidsbot) or add the bot to your channel and use [@RawDataBot](https://t.me/RawDataBot)
   - For groups: Add the bot to the group and check the chat ID
   - You can also use channel username format (e.g., `@channelname`)

4. **Configure the bot**:
   ```bash
   cp telegram_bot.yaml.example telegram_bot.yaml
   # Edit telegram_bot.yaml with your settings
   ```

5. **Start with Docker Compose** (see [Docker Deployment](#docker-deployment) section above):
   ```bash
   docker-compose up -d
   ```

The Docker setup includes all dependencies and is the simplest way to run the bot.

#### Alternative: Native Installation

1. **Install dependencies**:
   ```bash
   pip install -r requirements.txt
   ```

2. **Follow steps 1-4 above** to create bot and configure

3. **Run the bot**:
   ```bash
   # Option 1: Use the convenience script (recommended)
   ./run_telegram_bot.sh
   
   # Option 2: Manual setup
   python3 -m venv venv
   source venv/bin/activate  # On Cygwin/Windows: source venv/Scripts/activate
   pip install -r requirements.txt
   python3 telegram_bot.py
   
   # Option 3: Disable Firefox cookie support
   python3 telegram_bot.py --no-firefox
   
   # Option 4: Use custom config file
   python3 telegram_bot.py --config /path/to/custom_config.yaml
   
   # Option 5: Use cookies file
   python3 telegram_bot.py --cookies firefox_cookies.txt
   ```

### Usage

Once running, the bot will:
- Monitor configured channels/groups
- Process messages only from the owner (identified by `owner_id`) or from configured channels
- Extract URLs from messages
- Download media files (photos, videos, documents) and process them
- Extract any additional text after URLs or from captions
- Execute: `./nostr_media_uploader.sh -p <profile_name> <url1> <url2> ... "<extra_text>"`
- Send status updates back to Telegram with clickable Nostr links

**Examples**:
- **URL with text**: You post `https://instagram.com/p/ABC123 hello world`
  - Bot executes: `./nostr_media_uploader.sh -p tarado "https://instagram.com/p/ABC123" "hello world"`
- **Photo with caption**: You send a photo with caption "Beautiful sunset"
  - Bot downloads the photo and executes: `./nostr_media_uploader.sh -p tarado photo.jpg "Beautiful sunset"`
- **Video file**: You send a video file
  - Bot downloads the video and processes it with the uploader script

### Configuration

The bot configuration file (`telegram_bot.yaml`) uses YAML format:

```yaml
# Bot token from @BotFather
bot_token: YOUR_BOT_TOKEN_HERE

# Your Telegram user ID (get from @userinfobot)
owner_id: YOUR_TELEGRAM_USER_ID

# Path to nostr_media_uploader.sh script
script_path: ./nostr_media_uploader.sh

# Optional: Path to Cygwin installation (auto-detected if not specified)
# cygwin_root: F:\cygwin64

# Optional: Path to cookies file (Mozilla/Netscape format)
# If specified, will use --cookies option instead of --firefox
# cookies_file: ./firefox_cookies.txt

# Optional: Nostr client URL template for creating clickable links
# nostr_client_url: https://snort.social/e/{nevent}

# Channels configuration - each channel can have its own profile
channels:
  channel1:
    chat_id: -1001234567890  # Numeric chat ID
    profile_name: tarado
  channel2:
    chat_id: @channelname     # Channel username
    profile_name: girino
```

**Important Notes**:
- Each channel **must** have a `profile_name` - there is no default profile
- If no channels are configured, the bot will only process messages from the owner in private chats
- Channel posts are only processed if the channel is configured in `channels`
- You can use either numeric chat IDs or channel usernames (e.g., `@channelname`)

### Configuration Reload

You can reload the configuration without restarting the bot by sending `/reload` in a private chat with the bot. The bot will:
- Reload the configuration file
- Validate the new configuration
- Report the number of configured channels
- Continue running with the new settings

### Command-Line Options

- `--no-firefox`: Disable `--firefox` parameter when calling `nostr_media_uploader.sh`
- `--cookies <file>` / `--cookies-file <file>`: Use cookies from specified file (Mozilla/Netscape format). Takes precedence over `--firefox`
- `--config <path>`: Specify custom configuration file path (default: `telegram_bot.yaml`)

You can also set the config file path via environment variable:
```bash
export TELEGRAM_BOT_CONFIG=/path/to/telegram_bot.yaml
python3 telegram_bot.py
```

## Support

This project does not provide support or accept feature requests. If you encounter issues, please adapt the code yourself or refer to the documentation for troubleshooting guidance.

