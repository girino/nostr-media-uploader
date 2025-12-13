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
- `--source` / `--nosource`: Show/hide source URLs in posts
- `--password <password>`: Provide password for encrypted keys
- `--max-file-search <number>`: Maximum files to search when inferring Facebook image positions
- `-h`, `--help`: Show help message

### Examples

#### Video Upload with Firefox Cookies
```bash
./nostr_media_uploader.sh -firefox https://web.facebook.com/reel/1174103824690243
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
- **`APPEND_ORIGINAL_COMMENT`**: Append original captions (0/1, default: 1)

## Platform Support

- ✅ Linux (native)
- ✅ Cygwin (Windows)
- ⚠️ macOS (may work but not tested)

## Video Codec Support

The script automatically handles video codec conversion:

1. **Hardware-accelerated encoding** (if available):
   - H.265: Intel QSV (hevc_qsv), NVIDIA NVENC (hevc_nvenc), AMD AMF (hevc_amf)
   - H.264: Intel QSV (h264_qsv), NVIDIA NVENC (h264_nvenc), AMD AMF (h264_amf)

2. **Software encoding** (fallback):
   - H.265: libx265
   - H.264: libx264 (universal fallback)

The script automatically detects available hardware and selects the best encoder.

## Error Handling

- Automatic fallback between multiple blossom servers
- Hardware encoder detection with software fallback
- Intelligent codec conversion with multiple encoder attempts
- Comprehensive error messages with troubleshooting hints
- History tracking to prevent duplicate uploads

## History Tracking

The script maintains a history file (`${SCRIPT_NAME%.*}.history`) in the script directory to prevent duplicate uploads. Hashes of processed files and URLs are stored to avoid re-processing.

To disable history checking, use the `--nocheck` option.

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

The repository includes a Telegram bot (`telegram_bot.py`) that can automatically process links posted in a Telegram channel or group and upload them using `nostr_media_uploader.sh`.

### Setup

1. **Install dependencies**:
   ```bash
   pip install -r requirements.txt
   ```

2. **Create a Telegram bot**:
   - Talk to [@BotFather](https://t.me/BotFather) on Telegram
   - Use `/newbot` command to create a new bot
   - Save the bot token you receive

3. **Get your Telegram User ID**:
   - Talk to [@userinfobot](https://t.me/userinfobot) to get your user ID

4. **Get Chat ID** (for channel/group):
   - For channels: Use [@getidsbot](https://t.me/getidsbot) or add the bot to your channel and use [@RawDataBot](https://t.me/RawDataBot)
   - For groups: Add the bot to the group and check the chat ID
   - You can also use channel username format (e.g., `@channelname`)

5. **Configure the bot**:
   ```bash
   cp telegram_bot.conf.example telegram_bot.conf
   # Edit telegram_bot.conf with your settings:
   # - bot_token: Your bot token from BotFather
   # - owner_id: Your Telegram user ID
   # - chat_id: Channel/group ID or @channelname
   # - profile_name: Profile name to use (e.g., "tarado")
   # - script_path: Path to nostr_media_uploader.sh (default: ./nostr_media_uploader.sh)
   ```

6. **Run the bot**:
   ```bash
   # Option 1: Use the convenience script (recommended)
   ./run_telegram_bot.sh
   
   # Option 2: Manual setup
   python3 -m venv venv
   source venv/bin/activate  # On Cygwin/Windows: source venv/Scripts/activate
   pip install -r requirements.txt
   python3 telegram_bot.py
   ```

### Usage

Once running, the bot will:
- Monitor the specified channel/group
- Process messages only from the owner (identified by `owner_id`)
- Extract URLs from messages
- Extract any additional text after URLs
- Execute: `./nostr_media_uploader.sh -p <profile_name> <url1> <url2> ... "<extra_text>"`
- Send status updates back to Telegram

**Example**:
- You post: `https://instagram.com/p/ABC123 hello world`
- Bot executes: `./nostr_media_uploader.sh -p tarado "https://instagram.com/p/ABC123" "hello world"`

### Configuration

The bot configuration file (`telegram_bot.conf`) uses INI format:

```ini
[telegram]
bot_token = YOUR_BOT_TOKEN
owner_id = YOUR_TELEGRAM_USER_ID
chat_id = YOUR_CHAT_ID
profile_name = tarado
script_path = ./nostr_media_uploader.sh
```

You can also set the config file path via environment variable:
```bash
export TELEGRAM_BOT_CONFIG=/path/to/telegram_bot.conf
python3 telegram_bot.py
```

## Support

This project does not provide support or accept feature requests. If you encounter issues, please adapt the code yourself or refer to the documentation for troubleshooting guidance.

