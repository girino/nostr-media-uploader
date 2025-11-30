# Usage Guide

This guide provides detailed usage instructions for all scripts in this repository.

## nostr_media_uploader.sh

The main script for downloading media from URLs and uploading to Nostr.

### Basic Usage

```bash
# Download and upload from URL
./nostr_media_uploader.sh https://web.facebook.com/reel/1234567890

# Upload local files
./nostr_media_uploader.sh video.mp4 image.jpg "Description"

# Multiple URLs
./nostr_media_uploader.sh url1 url2 url3 "Description"
```

### Command-Line Options

#### Video Conversion
- `--convert`: Enable video conversion (default)
- `--noconvert`: Disable video conversion

#### Relay and Publishing
- `--norelay`: Don't send event to Nostr relays (upload only)
- `--nopow`: Disable proof of work (faster, less secure)

#### History and Duplicates
- `--nocheck`: Disable hash check (allows re-uploading same files)

#### Captions and Metadata
- `--comment`: Append original captions from media (default)
- `--nocomment`: Don't append original captions

#### Authentication
- `--firefox`: Use Firefox cookies for authenticated downloads
- `--password <password>`: Provide password for encrypted keys

#### Source Attribution
- `--source`: Show source URLs in posts
- `--nosource`: Don't show source URLs (default)

#### Advanced Options
- `--max-file-search <number>`: Maximum files to search when inferring Facebook image positions (default: 10)
- `-h`, `--help`: Show help message

### Examples

#### Download Facebook Reel
```bash
./nostr_media_uploader.sh -firefox https://web.facebook.com/reel/1174103824690243
```

#### Upload Local Video with Custom Caption
```bash
./nostr_media_uploader.sh video.mp4 "My custom caption"
```

#### Upload Multiple Images as Gallery
```bash
./nostr_media_uploader.sh img1.jpg img2.jpg img3.jpg "Gallery description"
```

#### Upload Without Publishing to Relays
```bash
./nostr_media_uploader.sh --norelay video.mp4
```

#### Upload with Source Attribution
```bash
./nostr_media_uploader.sh --source video.mp4 "Caption" "https://source.example.com"
```

## image_uploader.sh

Specialized script for downloading and uploading images from URLs.

### Basic Usage

```bash
# Download and upload image from URL
./image_uploader.sh https://instagram.com/p/ABC123

# With Firefox cookies
./image_uploader.sh -firefox https://instagram.com/p/ABC123

# Custom caption
./image_uploader.sh -firefox https://instagram.com/p/ABC123 "My caption"
```

### Options

- `-firefox`: Use Firefox cookies
- `-key <key>`: Private key (overrides config file)
- `-blossom <url>`: Use specific blossom server
- `-nocomment` / `-nocaption`: Don't use captions from gallery-dl
- `-nosource`: Don't add source URL to caption
- `-norelay`: Don't send event to relays
- `-nopow`: Disable proof of work

## aiart.sh

Profile-based uploader for AI-generated art with hashtag support.

### Basic Usage

```bash
# Upload files with default profile (tarado)
./aiart.sh image1.jpg image2.jpg "Description"

# Use specific profile
./aiart.sh -p myprofile image1.jpg image2.jpg

# With hashtags
./aiart.sh --tag ai --tag art image1.jpg "Description"
```

### Options

- `--profile=<name>` / `-p=<name>`: Use specified profile from ~/.nostr/
- `--tag <tag>` / `-t <tag>`: Add hashtag (can be used multiple times)

### Profiles

Profiles allow you to use different Nostr keys and configurations:

```bash
# Create a profile
cat > ~/.nostr/myprofile << EOF
NSEC_KEY="nsec1..."
BLOSSOMS=("https://blossom.example.com")
RELAYS=("wss://relay.example.com")
EOF

# Use the profile
./aiart.sh -p myprofile image.jpg
```

## Configuration Files

All scripts support environment-based configuration. Configuration files are located in `~/.nostr/`:

- `nostr_media_uploader.sh` → `~/.nostr/nostr_media_uploader`
- `image_uploader.sh` → `~/.nostr/image_uploader`
- `aiart.sh` → `~/.nostr/<profile_name>`

### Using Multiple Profiles with Symlinks

To use different profiles with different Nostr keys, you can create symlinks of the script with different names. The script automatically detects its name and looks for a configuration file based on that name (without the `.sh` extension).

**How it works:**

The script uses `basename "$0"` to get its name, then removes the `.sh` extension. This means:

- If you run `./nostr_media_uploader.sh`, it loads `~/.nostr/nostr_media_uploader`
- If you create a symlink `ln -s nostr_media_uploader.sh work_uploader.sh`, it loads `~/.nostr/work_uploader`
- If you create a symlink `ln -s nostr_media_uploader.sh personal_uploader.sh`, it loads `~/.nostr/personal_uploader`

**Example: Setting up multiple profiles**

```bash
# Create symlinks for different profiles
ln -s nostr_media_uploader.sh work_uploader.sh
ln -s nostr_media_uploader.sh personal_uploader.sh

# Create configuration files for each profile
cp example_env ~/.nostr/work_uploader
cp example_env ~/.nostr/personal_uploader

# Edit each config file with different keys
nano ~/.nostr/work_uploader      # Add work account NSEC_KEY
nano ~/.nostr/personal_uploader  # Add personal account NSEC_KEY

# Now use different profiles easily
./work_uploader.sh video.mp4           # Uses work account
./personal_uploader.sh video.mp4       # Uses personal account
./nostr_media_uploader.sh video.mp4    # Uses default account
```

**Benefits:**

- Easy to switch between accounts by using different symlink names
- No need to edit config files before each use
- Each profile can have different keys, relays, blossoms, and settings
- Works with all scripts: `nostr_media_uploader.sh`, `image_uploader.sh`, etc.

See [example_env](example_env) for configuration options.

## Common Use Cases

### Download and Share Facebook Content

```bash
# With Firefox cookies (logged into Facebook)
./nostr_media_uploader.sh -firefox https://web.facebook.com/reel/1234567890
```

### Upload Local Media Collection

```bash
# Upload multiple files with description
./nostr_media_uploader.sh file1.jpg file2.jpg file3.mp4 "My collection"
```

### Share Instagram Post

```bash
# Requires Firefox cookies if account is private
./image_uploader.sh -firefox https://instagram.com/p/ABC123
```

### Batch Upload AI Art

```bash
# Upload directory of images with hashtags
for img in images/*.jpg; do
    ./aiart.sh --tag ai --tag art "$img"
done
```

## Troubleshooting

### "Command not found" Errors

The script will automatically check for missing commands and provide installation instructions. Follow the instructions provided.

### Video Conversion Fails

1. Check that ffmpeg is installed with codec support
2. Verify hardware encoder availability (optional)
3. Software encoders will be used as fallback automatically

### Upload Fails

1. Check your Nostr key configuration
2. Verify blossom servers are accessible
3. Check network connectivity
4. Try with `--norelay` to test upload only

### Authentication Errors

For sites requiring login (e.g., private Facebook/Instagram):
1. Use `--firefox` flag to use Firefox cookies
2. Ensure you're logged into the site in Firefox
3. For gallery-dl, cookies are automatically extracted

For more help, see the [README.md](README.md) or open an issue.

