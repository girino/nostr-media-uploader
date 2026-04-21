#!/bin/bash

#set -e
BLOSSOMS=(
	"https://blossom.primal.net"
	"https://nostr.download"
	"https://cdn.nostrcheck.me"
)


# Shuffle the BLOSSOMS array
#BLOSSOMS=($(shuf -e "${BLOSSOMS[@]}"))

RELAYS=(
    "wss://bcast.girino.org"
    "wss://nip13.girino.org"
)

# parse parameters in any order. Positional parameter 1 is url. then there are -key parameter, and -firefox parameter
DECRYPTED_KEY=""
USE_FIREFOX=0
POW_DIFF=20
NO_COMMENT=0
NO_RELAY=0
CUSTOM_CAPTION=""
PRE_DOWNLOADED_DIR=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -key)
            if [[ -n "$2" && ! "$2" =~ ^- ]]; then
                DECRYPTED_KEY="$2"
                shift 2
            else
                echo "Error: -key requires a value."
                exit 1
            fi
            ;;
        -firefox)
            USE_FIREFOX=1
            shift
            ;;
        -nopow)
            POW_DIFF=0
            shift
            ;;
        -blossom)
            if [[ -n "$2" && ! "$2" =~ ^- ]]; then
                BLOSSOMS=("$2")
                shift 2
            else
                echo "Error: -blossom requires a server URL."
                exit 1
            fi
            ;;
        -nocomment|-nocaption)
            NO_COMMENT=1
            shift
            ;;
        -nosource)
            USE_SOURCE=0
            shift
            ;;
        -norelay)
            NO_RELAY=1
            shift
            ;;
        *)
            break
            ;;
    esac
done

if [ -z "$1" ]; then
    echo "Usage: $0 <url> [custom_caption] [options]"
    echo "Options:"
    echo "  -key <key>           Private key for signing"
    echo "  -firefox             Use Firefox cookies"
    echo "  -nopow               Disable proof of work"
    echo "  -blossom <url>       Use specific blossom server"
    echo "  -nocomment/-nocaption Don't use captions from gallery-dl"
    echo "  -nosource            Don't add source URL to caption"
    echo "  -norelay             Don't send event to relays"
    echo ""
    echo "If -nocomment/-nocaption is used and a second parameter is provided,"
    echo "it will be used as the custom caption for all images."
    exit 1
fi

# if DECRYPTED_KEY starts with nsec, use nak decode to get the private key
if [[ "$DECRYPTED_KEY" =~ ^nsec[0-9a-zA-Z]+ ]]; then
    echo "Using NSEC_KEY to decrypt the secret key"
    DECODED=$(nak decode "$DECRYPTED_KEY")
    if [ $? -ne 0 ]; then
        echo "Failed to decrypt the key"
        exit 1
    fi
    echo "Decoded: $DECODED"
    # Check if the decoded output is JSON (starts with {) or a hex key
    if echo "$DECODED" | grep -q '^{'; then
        # It's JSON, extract the private_key field
        DECRYPTED_KEY=$(echo "$DECODED" | jq -r .private_key)
    else
        # It's already a hex key, use it directly
        DECRYPTED_KEY="$DECODED"
    fi
fi

# check if key is a valid private key in hex format
if [[ -n "$DECRYPTED_KEY" && ! "$DECRYPTED_KEY" =~ ^[0-9a-fA-F]{64}$ ]]; then
    echo "Error: Invalid private key format. It should be a 64-character hex string."
    exit 1
fi

GALLERY_DL_PARAMS=()
if [ $USE_FIREFOX -eq 1 ]; then
    GALLERY_DL_PARAMS+=("--cookies-from-browser" "firefox")
fi
# Set Firefox user agent
GALLERY_DL_PARAMS+=("--user-agent" "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:120.0) Gecko/20100101 Firefox/120.0")
URL="$1"
# Check if there's a custom caption parameter (second positional argument)
if [ -n "$2" ]; then
    CUSTOM_CAPTION="$2"
    shift 2  # Remove URL and custom caption from arguments
else
    shift  # Remove URL from arguments
fi
# Remove "&set=a.XXXX" from Facebook URLs if present
if [[ "$URL" =~ facebook\.com ]]; then
    #then remove set=a.XXXX or set=gm.XXXX
    if [[ "$URL" =~ [?\&](set=a\.[0-9]+|set=gm\.[0-9]+) ]]; then
        # first try removing the set param
        URL_NOSET=$(echo "$URL" | sed -E 's/[?&]set=a\.[0-9]+//')
        URL_NOSET=$(echo "$URL_NOSET" | sed -E 's/[?&]set=gm\.[0-9]+//')
        # Try downloading to see if it works
        echo "Trying to remove set param, new URL: $URL_NOSET"
        TEST_TMPDIR=$(mktemp -d /tmp/gallery_dl_test_XXXXXXXX)
        WIN_TEST_TMPDIR=$(cygpath -w "$TEST_TMPDIR")
        echo "Testing download: gallery-dl \"${GALLERY_DL_PARAMS[@]}\" -f '{num}.{extension}' -D \"$WIN_TEST_TMPDIR\" --write-metadata \"$URL_NOSET\""
        gallery-dl "${GALLERY_DL_PARAMS[@]}" -f '{num}.{extension}' -D "$WIN_TEST_TMPDIR" --write-metadata "$URL_NOSET" 2>&1 >/dev/null
        if [ $? -eq 0 ] && [ "$(ls -A "$TEST_TMPDIR" 2>/dev/null)" ]; then
            URL="$URL_NOSET"
            echo "Download succeeded, removed set param, new URL: $URL"
            # Keep the test temp directory for later use
            PRE_DOWNLOADED_DIR="$TEST_TMPDIR"
        else
            echo "Download failed, trying to infer position"
            rm -rf "$TEST_TMPDIR"
        fi
    fi
    # set was not removed, so try to infer position
    if [[ "$URL" =~ [?\&](set=a\.[0-9]+|set=gm\.[0-9]+) ]]; then
        # Extract fbid from URL if present
        if [[ "$URL" =~ [?\&]fbid=([0-9]+) ]]; then
            FBID="${BASH_REMATCH[1]}"
            echo "Found fbid: $FBID"
            
            # Download images to find position of image with fbid
            echo "Finding position of image with fbid $FBID..."
            POSITION_TMPDIR=$(mktemp -d /tmp/gallery_dl_position_XXXXXXXX)
            WIN_POSITION_TMPDIR=$(cygpath -w "$POSITION_TMPDIR")
            
            # Download all images to find the one matching FBID
            gallery-dl "${GALLERY_DL_PARAMS[@]}" -f '{num}.{extension}' -D "$WIN_POSITION_TMPDIR" --write-metadata "$URL" 2>&1 >/dev/null
            if [ $? -eq 0 ] && [ "$(ls -A "$POSITION_TMPDIR" 2>/dev/null)" ]; then
                # Count the position of the image matching the fbid by checking metadata files
                POSITION=1
                FOUND=0
                # Sort files in numerical order
                files=($(ls "$POSITION_TMPDIR" | sort -V))
                for fname in "${files[@]}"; do
                    file="$POSITION_TMPDIR/$fname"
                    # Skip metadata files in the count
                    [[ "$file" == *.json ]] && continue
                    
                    # Check corresponding metadata file
                    meta="${file}.json"
                    if [ ! -f "$meta" ]; then
                        meta="${file%.*}.json"
                    fi
                    
                    if [ -f "$meta" ]; then
                        # Check if metadata contains the FBID in URL or filename
                        if grep -q "$FBID" "$meta" 2>/dev/null; then
                            echo "Found matching image at position $POSITION"
                            GALLERY_DL_PARAMS+=("--range" "$POSITION")
                            FOUND=1
                            break
                        fi
                    fi
                    ((POSITION++))
                done
                
                if [ $FOUND -eq 0 ]; then
                    echo "Could not find image with fbid $FBID, defaulting to range 1"
                    GALLERY_DL_PARAMS+=("--range" "1")
                fi
                
                # Clean up position finding temp directory
                rm -rf "$POSITION_TMPDIR"
            else
                echo "Could not download to determine position, defaulting to range 1"
                GALLERY_DL_PARAMS+=("--range" "1")
                rm -rf "$POSITION_TMPDIR"
            fi
        else
            GALLERY_DL_PARAMS+=("--range" "1")
        fi
    fi
    echo "Modified URL: $URL"
fi

SCRIPT_NAME=$(basename "$0")
# Remove 'img' or 'img.sh' from script name for env var file
ENV_SCRIPT_NAME="${SCRIPT_NAME%img}"
ENV_SCRIPT_NAME="${ENV_SCRIPT_NAME%.sh}"
ENV_SCRIPT_NAME="${ENV_SCRIPT_NAME%img}"

# Load environment variables from ~/.nostr/${SCRIPT_NAME%.*}
if [[ -f "$HOME/.nostr/${ENV_SCRIPT_NAME}" ]]; then
    # shellcheck source=/dev/null
    source "$HOME/.nostr/${ENV_SCRIPT_NAME}"
else
	echo "No environment variables found in ~/.nostr/${ENV_SCRIPT_NAME}"
	exit 1
fi

# Default values
USE_SOURCE="${USE_SOURCE:-0}"
POW_DIFF="${POW_DIFF:-20}"

# add EXTRA_RELAYS to RELAYS if exists
if [[ -n "${EXTRA_RELAYS[*]}" ]]; then
	for RELAY in "${EXTRA_RELAYS[@]}"; do
		RELAYS+=("$RELAY")
	done
fi
# if DISPLAY_SOURCE exists, use it
if [[ -n "${DISPLAY_SOURCE}" ]]; then
	USE_SOURCE="${DISPLAY_SOURCE}"
fi

# add EXTRA_BLOSSOMS in front of BLOSSOMS if exists
if [[ -n "${EXTRA_BLOSSOMS[*]}" ]]; then
	BLOSSOMS=("${EXTRA_BLOSSOMS[@]}" "${BLOSSOMS[@]}")
fi


# Ensure that at least one key variable is set, otherwise exit with error
if [[ -z "$NSEC_KEY" && -z "$KEY" && -z "$NCRYPT_KEY" && -z "$DECRYPTED_KEY" ]]; then
    echo "Error: No key variable is set. Please set NSEC_KEY, KEY, NCRYPT_KEY, or DECRYPTED_KEY in ~/.nostr/${ENV_SCRIPT_NAME}"
    exit 1
fi


# if exists NPUB_KEY, use "nak decode | jq -r .private_key" to get it. 
# bypass decrypting
if [ -n "$DECRYPTED_KEY" ]; then
    echo "Using provided decrypted key"
    KEY="$DECRYPTED_KEY"
elif [ -n "$NSEC_KEY" ]; then
	echo "Using NSEC_KEY to decrypt the secret key"
	DECODED=$(nak decode $NSEC_KEY)
	if [ $? -ne 0 ]; then
		echo "Failed to decrypt the key"
		exit 1
	fi
	
	# Check if the decoded output is JSON (starts with {) or a hex key
	if echo "$DECODED" | grep -q '^{'; then
		# It's JSON, extract the private_key field
		KEY=$(echo "$DECODED" | jq -r .private_key)
	else
		# It's already a hex key, use it directly
		KEY="$DECODED"
	fi
elif [ -n "$NCRYPT_KEY" ]; then
	echo "Using NCRYPT_KEY to decrypt the secret key"
	if [ -z "$PASSWORD" ]; then
		read -sp "Enter password to decrypt the secret key: " PASSWORD
		echo
	fi
	KEY=$(nak key decrypt "$NCRYPT_KEY" "$PASSWORD")
	if [ $? -ne 0 ]; then
		echo "Failed to decrypt the key"
		exit 1
	fi
else
    echo "Using default key"
	if [ -z "$KEY" ]; then
		echo "Key is empty, cannot decrypt"
		exit 1
	fi
	read -sp "Enter password to decrypt the secret key: " PASSWORD
	echo
	KEY=$(echo "$KEY" | openssl enc -aes-256-cbc -pbkdf2 -d -a -pass pass:"$PASSWORD")
	if [ $? -ne 0 ]; then
		echo "Failed to decrypt the key"
		exit 1
	fi
fi

TMPDIR=$(mktemp -d /tmp/gallery_dl_XXXXXXXX)
mkdir -p "$TMPDIR"
WIN_TMPDIR=$(cygpath -w "$TMPDIR")

function cleanup {
    echo "Cleaning up temporary files..."
    #rm -rf "$TMPDIR"
    if [ -n "$PRE_DOWNLOADED_DIR" ] && [ -d "$PRE_DOWNLOADED_DIR" ]; then
        rm -rf "$PRE_DOWNLOADED_DIR"
    fi
}
trap cleanup EXIT

# Check if we already downloaded files earlier
if [ -n "$PRE_DOWNLOADED_DIR" ] && [ -d "$PRE_DOWNLOADED_DIR" ] && [ "$(ls -A "$PRE_DOWNLOADED_DIR" 2>/dev/null)" ]; then
    echo "Using pre-downloaded files from test download (already includes metadata)"
    # Copy files from pre-downloaded directory to TMPDIR
    cp -r "$PRE_DOWNLOADED_DIR"/* "$TMPDIR"/ 2>/dev/null || true
else
    # Download images and metadata
    gallery-dl "${GALLERY_DL_PARAMS[@]}" -f '{num}.{extension}' -D "$WIN_TMPDIR" --write-metadata "$URL"
    if [ $? -ne 0 ]; then
        echo "Error: gallery-dl failed to download images or metadata."
        exit 2
    fi
fi
# Check if any files were downloaded
if [ ! "$(ls -A "$TMPDIR")" ]; then
    echo "Error: No files were downloaded."
    exit 3
fi

# Initialize an empty array to store URLs
URLS=()
captions=()
types=()
sizes=()
# bad servers
BAD_SERVERS=()
# Process each downloaded file
# Sort files in numerical order (by filename)
files=($(ls "$TMPDIR" | sort -V))
for fname in "${files[@]}"; do
    file="$TMPDIR/$fname"
    winfile=$(cygpath -w "$file")
    # Skip metadata files
    [[ "$file" == *.json ]] && continue
    echo "Processing file: $file ($winfile)"

    # Find corresponding metadata file
    meta="${file}.json"
    if [ ! -f "$meta" ]; then
        # Try to find metadata file with just extension replaced
        meta="${file%.*}.json"
        [ ! -f "$meta" ] && continue
    fi

    # Handle caption based on NO_COMMENT flag
    if [ $NO_COMMENT -eq 1 ]; then
        # Use custom caption if provided, otherwise empty
        caption="$CUSTOM_CAPTION"
    else
        # Remove leading/trailing quotes if present, but do not parse escapes
        caption=$(jq '.caption // empty' "$meta")
        caption="${caption%\"}"
        caption="${caption#\"}"
    fi
    captions+=("$caption")

    # Upload file
    upload_success=0
    for server in "${BLOSSOMS[@]}"; do
        # if server in BADSERVERS then skip it
        if [[ " ${BAD_SERVERS[@]} " =~ " $server " ]]; then
            echo "Skipping bad server: $server"
            continue
        fi
        upload_output=$(nak blossom upload --server "$server" "$winfile")
        if [ $? -eq 0 ]; then
            upload_success=1
            break
        else
            BAD_SERVERS+=("$server")
            echo "Upload to $server failed. Trying next server..."
            echo "Error: $upload_output"
        fi
    done

    if [ $upload_success -eq 0 ]; then
        echo "Error: Failed to upload $file to all servers."
        continue
    fi

    # Extract URL (assuming output contains a URL)
    file_url=$(echo "$upload_output" | jq -r '.url')
    URLS+=("$file_url")
    type=$(echo "$upload_output" | jq -r '.type')
    types+=("$type")
    size=$(echo "$upload_output" | jq -r '.size')
    sizes+=("$size")
done

# Build the event content
event_content=""
tags=()
for i in "${!URLS[@]}"; do
    echo "Adding URL: ${URLS[$i]}"
    url="${URLS[$i]}"
    caption="${captions[$i]}"
    type="${types[$i]}"
    size="${sizes[$i]}"
    if [ -n "$event_content" ]; then
        event_content="${event_content}\n\n"
    fi
    event_content="${event_content}${url}"
    if [ -n "$caption" ]; then
        event_content="${event_content}\n${caption}"
    fi
    tags+=("imeta=url $url;m $type")
done
# Add custom caption after all images if -nocomment is not used and custom caption is provided
if [ $NO_COMMENT -eq 0 ] && [ -n "$CUSTOM_CAPTION" ]; then
    event_content="${event_content}\n\n${CUSTOM_CAPTION}"
fi
# add source
if [ $USE_SOURCE -eq 1 ]; then
    # remove param idorvanity= first, since it breaks gallery-dl
    SOURCE_URL="$URL"
    if [[ "$SOURCE_URL" =~ [?\&]idorvanity=[0-9]+ ]]; then
        SOURCE_URL=$(echo "$SOURCE_URL" | sed -E 's/[?&]idorvanity=[0-9]+//')
    fi
    # remove param __cft__[0]= if present
    if [[ "$SOURCE_URL" =~ [?\&]__cft__\[0\]=[^\&]+ ]]; then
        SOURCE_URL=$(echo "$SOURCE_URL" | sed -E 's/[?&]__cft__\[0\]=[^&]+//')
    fi
    # remove param __tn__= if present
    if [[ "$SOURCE_URL" =~ [?\&]__tn__=[^\&]+ ]]; then
        SOURCE_URL=$(echo "$SOURCE_URL" | sed -E 's/[?&]__tn__=[^&]+//')
    fi
    echo "Source URL: $SOURCE_URL"
    event_content="${event_content}\n\nSource: $SOURCE_URL"
fi

# Prepare tags for nak command
tag_args=()
if [ ${#tags[@]} -gt 0 ]; then
    for tag in "${tags[@]}"; do
        tag_args+=("-t" "$tag")
    done
fi
echo "Tags: ${tag_args[*]}"

# Extract hashtags from event_content
hashtags=($(echo -e "$event_content" | grep -oE '#[A-Za-z0-9_]+' | sort -u))

# Add hashtags as tags
for tag in "${hashtags[@]}"; do
    # Remove the leading '#' for the tag value
    tag_args+=("-t" "t=$(echo "$tag" | sed 's/^#//')")
done

# Create the kind 1 nostr event using nak
CMD=("nak")
CMD+=("event" "--auth" "-sec" "$KEY" "--kind" "1" "--content" "$(echo -e "$event_content")")
CMD+=("${tag_args[@]}")
if [ $POW_DIFF -gt 0 ]; then
    CMD+=("--pow" "$POW_DIFF")
fi
# Add relays if any and not disabled
if [ $NO_RELAY -eq 0 ] && [ -n "${RELAYS[*]}" ]; then
    for relay in "${RELAYS[@]}"; do
        CMD+=("$relay")
    done
fi
echo "CMD: ${CMD[*]}"
"${CMD[@]}"
