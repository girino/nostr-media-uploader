# Installation Guide

This guide provides detailed installation instructions for Nostr Media Uploader on different platforms.

## Platform Support

- ✅ **Linux** (Debian/Ubuntu, RHEL/CentOS, Fedora, etc.)
- ✅ **Cygwin** (Windows)
- ⚠️ **macOS** (may work but not fully tested)

## Prerequisites

Before installing, ensure you have:
- Bash shell (version 4.0 or later)
- Python 3.6 or later
- Access to package managers (apt, yum, dnf, pip, etc.)

## Step 1: Install System Dependencies

### Linux (Debian/Ubuntu)

```bash
sudo apt-get update
sudo apt-get install -y ffmpeg jq file coreutils
```

### Linux (RHEL/CentOS)

```bash
sudo yum install -y ffmpeg jq file coreutils
```

### Linux (Fedora)

```bash
sudo dnf install -y ffmpeg jq file coreutils
```

### Cygwin

```bash
apt-cyg install ffmpeg jq file coreutils
```

## Step 2: Install Python Dependencies

### Important: Package Manager Versions are Too Old

**DO NOT** use system package managers (apt, yum) for `gallery-dl` and `yt-dlp` - they contain outdated versions that don't work with modern social media platforms.

### Recommended: Use pipx (Linux)

```bash
# Install pipx
sudo apt install pipx  # or: sudo dnf install pipx

# Ensure pipx binaries are in PATH
pipx ensurepath

# Install gallery-dl (requires >= 1.30.6 for Facebook support)
pipx install gallery-dl==1.30.6

# Install yt-dlp
pipx install yt-dlp
```

### Alternative: Use pip with --user flag (Linux)

```bash
# Install gallery-dl (requires >= 1.30.6)
pip install --user gallery-dl==1.30.6

# Install yt-dlp
pip install --user yt-dlp

# Add user bin directory to PATH (if not already)
export PATH="$HOME/.local/bin:$PATH"
```

### Cygwin

```bash
# Install gallery-dl (requires >= 1.30.6)
pip install gallery-dl==1.30.6

# Install yt-dlp
pip install yt-dlp
```

### Verify Installations

```bash
# Check gallery-dl version (must be >= 1.30.6)
gallery-dl --version

# Check yt-dlp
yt-dlp --version

# Check ffmpeg
ffmpeg -version
```

## Step 3: Install Nostr Tools

### Install nak

`nak` is a command-line tool for Nostr operations. Installation methods:

#### From Source (Recommended)

```bash
git clone https://github.com/fiatjaf/nak.git
cd nak
go build -o nak
sudo cp nak /usr/local/bin/  # or add to your PATH
```

#### Using Go Install

```bash
go install github.com/fiatjaf/nak@latest
```

#### Pre-compiled Binaries

Download from: https://github.com/fiatjaf/nak/releases

### Install blossom-cli (Optional)

`blossom-cli` is used as a fallback upload tool. It's optional but recommended.

```bash
# Installation instructions at: https://github.com/fiatjaf/blossom
# Or build from source
```

## Step 4: Install Scripts

### Clone Repository

```bash
git clone <repository-url>
cd reels_uploader  # or your chosen repository name
```

### Make Scripts Executable

```bash
chmod +x nostr_media_uploader.sh
chmod +x image_uploader.sh
chmod +x aiart.sh
```

## Step 5: Configure Environment

### Create Configuration Directory

```bash
mkdir -p ~/.nostr
```

### Create Configuration File

Copy the example configuration:

```bash
cp example_env ~/.nostr/nostr_media_uploader
```

### Edit Configuration

Edit `~/.nostr/nostr_media_uploader` with your Nostr keys:

```bash
nano ~/.nostr/nostr_media_uploader
# or
vim ~/.nostr/nostr_media_uploader
```

**Minimum required configuration:**

```bash
NSEC_KEY="nsec1yourkeyhere"
```

See [example_env](example_env) for all configuration options.

### Get Your Nostr Key

You can get your nsec key from:
- Your Nostr client (Amethyst, Damus, etc.)
- Generate a new key: `nak key generate`
- Export from existing client

## Step 6: Verify Installation

### Check Required Commands

The scripts will automatically check for required commands on first run. You can also verify manually:

```bash
# Check all required commands
command -v gallery-dl && echo "✓ gallery-dl found"
command -v yt-dlp && echo "✓ yt-dlp found"
command -v ffmpeg && echo "✓ ffmpeg found"
command -v ffprobe && echo "✓ ffprobe found"
command -v jq && echo "✓ jq found"
command -v nak && echo "✓ nak found"
command -v sha256sum && echo "✓ sha256sum found"
command -v file && echo "✓ file found"
```

### Test Installation

```bash
# Test with help option
./nostr_media_uploader.sh --help

# The script will check for missing dependencies and provide instructions
```

## Troubleshooting

### gallery-dl Version Too Old

**Error**: `gallery-dl version X.X.X found, but version >= 1.30.6 is required`

**Solution**:

```bash
# On Linux (using pipx)
pipx install --force gallery-dl==1.30.6

# On Linux (using pip)
pip install --user --upgrade gallery-dl==1.30.6

# On Cygwin
pip install --upgrade gallery-dl==1.30.6
```

### Python Package Installation Fails

**Error**: `externally-managed-environment` on modern Linux systems

**Solution**: Always use `--user` flag or `pipx`:

```bash
# Use pipx (recommended)
pipx install gallery-dl==1.30.6

# Or use --user flag
pip install --user gallery-dl==1.30.6
```

### ffmpeg Codec Not Found

**Error**: Video conversion fails with codec errors

**Solution**: Install ffmpeg with full codec support:

```bash
# On Debian/Ubuntu
sudo apt-get install -y ffmpeg

# Verify codec support
ffmpeg -codecs | grep -E "h264|hevc"
```

### nak Command Not Found

**Error**: `nak: command not found`

**Solution**:
1. Verify `nak` is installed: `which nak`
2. Add to PATH if installed in non-standard location
3. Or install using one of the methods above

### Configuration File Not Found

**Error**: `No key variable is set`

**Solution**: Create and configure your environment file:

```bash
mkdir -p ~/.nostr
cp example_env ~/.nostr/nostr_media_uploader
# Edit the file and add your NSEC_KEY
```

## Hardware Acceleration (Optional)

For faster video encoding, hardware acceleration can be enabled:

### Intel QuickSync (QSV)

- Automatically detected on Linux if Intel GPU is present
- Requires DRI devices: `/dev/dri/renderD*`
- Usually works out-of-the-box on modern Intel systems

### NVIDIA NVENC

- Requires NVIDIA GPU and drivers
- Check availability: `nvidia-smi -L`
- Automatically detected if available

### AMD AMF

- Requires AMD GPU with Mesa drivers
- Automatically detected if available

**Note**: Software encoding (libx264/libx265) will be used as fallback if hardware acceleration is not available.

## Next Steps

After installation:
1. Configure your Nostr keys in `~/.nostr/nostr_media_uploader`
2. Test with a simple upload: `./nostr_media_uploader.sh --help`
3. Read the [README.md](README.md) for usage examples
4. Check configuration options in [example_env](example_env)

## Support

If you encounter issues during installation:
1. Check that all dependencies are installed correctly
2. Verify your configuration file is set up properly
3. Check the script's error messages for specific guidance
4. Open an issue on the repository with details

