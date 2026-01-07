#!/bin/bash

usage () {
    echo "Usage: $0 [--profile=PROFILE|-profile=PROFILE|-p=PROFILE] [--blossom=SERVER] [--file-drop=URL] [--tag=TAG] [--nsfw] [file1] [file2] ... [comment]"
    echo "Uploads files to Blossom servers and creates a kind 1 event with the URLs."
    echo "Files can be specified as individual files or directories containing files."
    echo "The last argument is treated as a comment for the event."
    echo ""
    echo "Options:"
    echo "  --profile=PROFILE    Use the specified profile from ~/.nostr/ (default: girino)"
    echo "  -profile=PROFILE     Short form of --profile"
    echo "  -p=PROFILE           Shortcut for -profile=PROFILE"
    echo "  --blossom=SERVER     Use an alternative Blossom server (can be used multiple times)"
    echo "  -blossom=SERVER      Short form of --blossom"
    echo "  --file-drop=URL      Use file-drop server for uploads (e.g., http://192.168.31.103:3232/upload)"
    echo "                       If file-drop fails, falls back to blossom servers"
    echo "                       Can also be set via FILE_DROP_URL environment variable"
    echo "  --file-drop-url-prefix=PREFIX  Replace https://dweb.link/ prefix in file-drop URLs"
    echo "                                 with custom prefix (e.g., https://gateway.example.com)"
    echo "                                 Can also be set via FILE_DROP_URL_PREFIX environment variable"
    echo "  --tag=TAG            Add an additional hashtag to the event (can be used multiple times)"
    echo "  -t TAG, --tag TAG    Alternative form for --tag"
    echo "  --nsfw               Mark the post as NSFW by adding content-warning tag"
    echo "                       Can also be set via NSFW=1 environment variable in config file"
    echo "                       Automatically enabled if #NSFW or #nsfw hashtag is found in content"
}

# Default profile
PROFILE="tarado"

# Function to validate profile
validate_profile() {
    local profile="$1"
    local nostr_dir="$HOME/.nostr"
    
    if [[ ! -d "$nostr_dir" ]]; then
        echo "Error: ~/.nostr directory does not exist"
        exit 1
    fi
    
    if [[ ! -f "$nostr_dir/$profile" ]]; then
        echo "Error: Profile '$profile' not found in ~/.nostr/"
        echo "Available profiles:"
        ls -1 "$nostr_dir" 2>/dev/null | grep -v '^\.' || echo "  (no profiles found)"
        exit 1
    fi
    
    return 0
}

# Function to set profile from parameter
set_profile() {
    local profile="$1"
    if [[ -z "$profile" ]]; then
        echo "Error: Empty profile specified"
        usage
        exit 1
    fi
    validate_profile "$profile"
    PROFILE="$profile"
}

# Parse profile parameter from command line arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --profile=*)
            set_profile "${1#--profile=}"
            shift
            ;;
        --profile)
            shift
            set_profile "$1"
            shift
            ;;
        -profile=*)
            set_profile "${1#-profile=}"
            shift
            ;;
        -profile)
            shift
            set_profile "$1"
            shift
            ;;
        -p=*)
            set_profile "${1#-p=}"
            shift
            ;;
        -p)
            shift
            set_profile "$1"
            shift
            ;;
        *)
            # Not a profile parameter, break out of this loop
            break
            ;;
    esac
done

# Load environment variables from the selected profile
if [[ -f "$HOME/.nostr/$PROFILE" ]]; then
    echo "Loading profile: $PROFILE"
    # shellcheck source=/dev/null
    source "$HOME/.nostr/$PROFILE"
else
    echo "Error: Profile file $HOME/.nostr/$PROFILE not found"
    exit 1
fi
# Default values
# Check if POW_DIFF is set, otherwise default to 20
if [[ -z "$POW_DIFF" ]]; then
    POW_DIFF=20
fi
if [[ -z "${BLOSSOMS[*]}" ]]; then
    echo "Using default BLOSSOMS"
    BLOSSOM_SERVERS=(
	    "https://blossom.primal.net"
	    "https://nostr.download"
	    "https://cdn.nostrcheck.me"
    )
else
    echo "Using provided BLOSSOMS: ${BLOSSOMS[@]}"
    BLOSSOM_SERVERS=("${BLOSSOMS[@]}")
fi

# Check for EXTRA_BLOSSOMS and add them to the front of BLOSSOM_SERVERS
if [[ -n "${EXTRA_BLOSSOMS[*]}" ]]; then
    echo "Adding EXTRA_BLOSSOMS to BLOSSOM_SERVERS: ${EXTRA_BLOSSOMS[@]}"
    BLOSSOM_SERVERS=("${EXTRA_BLOSSOMS[@]}" "${BLOSSOM_SERVERS[@]}")
fi

# Note: CMD_LINE_BLOSSOMS will be processed after parsing command line arguments


if [[ -z "$NSEC_KEY" && -z "$KEY" ]]; then
    echo "Error: Neither NSEC_KEY nor KEY is set."
    exit 1
fi

# Set default relays
DEFAULT_RELAYS=(
    "wss://bcast.girino.org"
    "wss://wot.girino.org"
    "wss://nip13.girino.org"
)
if [[ -z "${RELAYS[*]}" ]]; then
    RELAYS=("${DEFAULT_RELAYS[@]}")
fi
if [[ -n "${EXTRA_RELAYS[*]}" ]]; then
    for RELAY in "${EXTRA_RELAYS[@]}"; do
        RELAYS+=("$RELAY")
    done
fi

FILES=()
COMMENT=""
URLS=()
FOUND_COMMENT=0
EXTRA_TAGS=()
NSFW=0

# Function to check if a file is image/* or video/*
is_image_or_video() {
    local file="$1"
    local mimetype
    mimetype=$(file --mime-type -b "$file")
    if [[ $mimetype == image/* || $mimetype == video/* ]]; then
        echo 1
    else
        echo 0
    fi
}

# Function to upload a file to a file-drop server
# Parameters:
#   $1: FILE - path to file to upload
#   $2: FILE_DROP_URL - file-drop server upload URL (e.g., http://192.168.31.103:3232/upload)
#   $3: URL_PREFIX - optional URL prefix to replace https://dweb.link/ (empty if not set)
# Returns: uploaded file URL via stdout (with prefix replaced if URL_PREFIX is set)
# Exit code: 0 on success, 1 on failure
upload_file_to_filedrop() {
    local FILE="$1"
    local FILE_DROP_URL="$2"
    local URL_PREFIX="${3:-}"
    
    if [[ ! -f "$FILE" ]]; then
        echo "File does not exist: $FILE" >&2
        return 1
    fi
    
    echo "Uploading $FILE to file-drop server: $FILE_DROP_URL" >&2
    local upload_output=$(curl -s -X POST -F "file=@$FILE" "$FILE_DROP_URL" 2>&1)
    local RESULT=$?
    
    if [[ $RESULT -ne 0 ]]; then
        echo "Failed to upload file $FILE to file-drop server: $upload_output" >&2
        return 1
    fi
    
    # Check if output is valid JSON
    if ! echo "$upload_output" | jq . >/dev/null 2>&1; then
        echo "Invalid JSON response from file-drop server: $upload_output" >&2
        return 1
    fi
    
    local file_url=$(echo "$upload_output" | jq -r '.url')
    if [[ -z "$file_url" || "$file_url" == "null" ]]; then
        echo "Failed to extract URL from file-drop response: $upload_output" >&2
        return 1
    fi
    
    # Replace URL prefix if URL_PREFIX is set
    if [[ -n "$URL_PREFIX" ]]; then
        # Remove trailing slash from prefix if present
        URL_PREFIX=$(echo "$URL_PREFIX" | sed 's:/*$::')
        # Replace https://dweb.link/ with the custom prefix
        file_url=$(echo "$file_url" | sed "s|^https://dweb\.link/|${URL_PREFIX}/|")
        echo "Replaced URL prefix with: $URL_PREFIX" >&2
    fi
    
    echo "Uploaded to: $file_url" >&2
    echo "$file_url"
    return 0
}

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

# Parse positional parameters
EXTRA_TAGS=()
CMD_LINE_BLOSSOMS=()
FILE_DROP_URL="${FILE_DROP_URL:-}"  # Initialize from environment if set
FILE_DROP_URL_PREFIX="${FILE_DROP_URL_PREFIX:-}"  # Initialize from environment if set
# Initialize NSFW from environment if set, normalize to 0/1
if [[ -n "${NSFW:-}" ]]; then
    # Normalize NSFW value (accept 1, true, yes)
    if [[ "${NSFW}" == "1" ]] || [[ "${NSFW}" == "true" ]] || [[ "${NSFW}" == "yes" ]]; then
        NSFW=1
    else
        NSFW=0
    fi
else
    NSFW=0
fi
# Parse positional and non-positional parameters using shift
while [[ $# -gt 0 ]]; do
    ARG="$1"
    case "$ARG" in
        --blossom=*)
            BLOSSOM_SERVER="${ARG#--blossom=}"
            if [[ -z "$BLOSSOM_SERVER" ]]; then
                echo "Missing value for $ARG"
                usage
                exit 1
            fi
            CMD_LINE_BLOSSOMS+=("$BLOSSOM_SERVER")
            shift
            ;;
        --blossom|-blossom)
            shift
            BLOSSOM_SERVER="$1"
            if [[ -z "$BLOSSOM_SERVER" ]]; then
                echo "Missing value for $ARG"
                usage
                exit 1
            fi
            CMD_LINE_BLOSSOMS+=("$BLOSSOM_SERVER")
            shift
            ;;
        -blossom=*)
            BLOSSOM_SERVER="${ARG#-blossom=}"
            if [[ -z "$BLOSSOM_SERVER" ]]; then
                echo "Missing value for $ARG"
                usage
                exit 1
            fi
            CMD_LINE_BLOSSOMS+=("$BLOSSOM_SERVER")
            shift
            ;;
        --file-drop=*)
            FILE_DROP_URL="${ARG#--file-drop=}"
            if [[ -z "$FILE_DROP_URL" ]]; then
                echo "Missing value for $ARG"
                usage
                exit 1
            fi
            shift
            ;;
        --file-drop)
            shift
            FILE_DROP_URL="$1"
            if [[ -z "$FILE_DROP_URL" ]]; then
                echo "Missing value for --file-drop"
                usage
                exit 1
            fi
            shift
            ;;
        --file-drop-url-prefix=*)
            FILE_DROP_URL_PREFIX="${ARG#--file-drop-url-prefix=}"
            if [[ -z "$FILE_DROP_URL_PREFIX" ]]; then
                echo "Missing value for $ARG"
                usage
                exit 1
            fi
            shift
            ;;
        --file-drop-url-prefix)
            shift
            FILE_DROP_URL_PREFIX="$1"
            if [[ -z "$FILE_DROP_URL_PREFIX" ]]; then
                echo "Missing value for --file-drop-url-prefix"
                usage
                exit 1
            fi
            shift
            ;;
        --tag=*)
            TAG="${ARG#--tag=}"
            if [[ -z "$TAG" ]]; then
                echo "Missing value for $ARG"
                usage
                exit 1
            fi
            EXTRA_TAGS+=("$TAG")
            shift
            ;;
        --tag|-t)
            shift
            TAG="$1"
            if [[ -z "$TAG" ]]; then
                echo "Missing value for $ARG"
                usage
                exit 1
            fi
            EXTRA_TAGS+=("$TAG")
            shift
            ;;
        --nsfw|-nsfw)
            NSFW=1
            shift
            ;;
        --)
            shift
            break
            ;;
        -*)
            echo "Unknown option: $ARG"
            usage
            exit 1
            ;;
        *)
            if [[ $FOUND_COMMENT -eq 1 ]]; then
                echo "Too many arguments after comment: $ARG"
                usage
                exit 1
            fi
            if [[ -f "$ARG" ]]; then
                if [[ $(is_image_or_video "$ARG") -ne 1 ]]; then
                    echo "Error: File '$ARG' is not an image or video (found mime type: $(file --mime-type -b "$ARG"))"
                    exit 1
                fi
                FILES+=("$ARG")
                shift
            elif [[ -d "$ARG" ]]; then
                while IFS= read -r -d '' f; do
                    if [[ -f "$f" ]] && [[ $(is_image_or_video "$f") -eq 1 ]]; then
                        FILES+=("$f")
                    fi
                done < <(find "$ARG" -type f -print0)
                shift
            else
                FOUND_COMMENT=1
                COMMENT="$ARG"
                shift
            fi
            ;;
    esac
done

# Apply command-line blossom servers (prepend them to the front)
if [[ ${#CMD_LINE_BLOSSOMS[@]} -gt 0 ]]; then
    echo "Adding command-line blossom servers to BLOSSOM_SERVERS: ${CMD_LINE_BLOSSOMS[@]}"
    BLOSSOM_SERVERS=("${CMD_LINE_BLOSSOMS[@]}" "${BLOSSOM_SERVERS[@]}")
fi

# If there are more arguments after the comment, ignore them

if [[ ${#FILES[@]} -eq 0 ]]; then
    echo "No valid files found to upload."
    exit 1
fi

# Check mime types of all files
for FILE in "${FILES[@]}"; do
    if [[ $(is_image_or_video "$FILE") -ne 1 ]]; then
        echo "Error: File '$FILE' is not an image or video (found mime type: $(file --mime-type -b "$FILE"))"
        exit 1
    fi
done

# Upload files to file-drop or Blossom servers, collect URLs
BAD_SERVERS=()
for FILE in "${FILES[@]}"; do
    UPLOADED=0
    
    # Try file-drop first if configured
    if [[ -n "$FILE_DROP_URL" ]]; then
        echo "Trying file-drop server for $FILE: $FILE_DROP_URL"
        URL=$(upload_file_to_filedrop "$FILE" "$FILE_DROP_URL" "$FILE_DROP_URL_PREFIX")
        if [[ $? -eq 0 && -n "$URL" ]]; then
            URLS+=("$URL")
            echo "Successfully uploaded $FILE to file-drop server: $URL"
            UPLOADED=1
        else
            echo "File-drop upload failed for $FILE, falling back to blossom servers" >&2
        fi
    fi
    
    # If file-drop not configured or failed, try blossom servers
    if [[ $UPLOADED -eq 0 ]]; then
        for SERVER in "${BLOSSOM_SERVERS[@]}"; do
            echo "Uploading $FILE to $SERVER"
            # Skip bad servers
            if [[ " ${BAD_SERVERS[@]} " =~ " $SERVER " ]]; then
                continue
            fi
            JSON_RET=$(nak blossom upload --server "$SERVER" "$FILE" 2>/dev/null)
            if [[ $? -ne 0 ]]; then
                echo "Error: Failed to upload $FILE to $SERVER"
                BAD_SERVERS+=("$SERVER")
                continue
            fi
            # Extract URL from JSON response
            URL=$(echo "$JSON_RET" | jq -r '.url // empty')
            if [[ -n "$URL" ]]; then
                URLS+=("$URL")
                echo "Uploaded $FILE to $SERVER: $URL"
                UPLOADED=1
                break
            fi
        done
    fi
    
    if [[ $UPLOADED -eq 0 ]]; then
        if [[ -n "$FILE_DROP_URL" ]]; then
            echo "Failed to upload $FILE to file-drop server or any Blossom server."
        else
            echo "Failed to upload $FILE to any Blossom server."
        fi
        exit 1
    fi
done

if [[ ${#URLS[@]} -eq 0 ]]; then
    echo "No files were uploaded successfully."
    exit 1
fi

# Prepare content for kind 1 event
CONTENT=""
if [[ -n "$COMMENT" ]]; then
    CONTENT="$COMMENT"$'\n'
fi
CONTENT+=$(printf "%s\n" "${URLS[@]}")
CONTENT+=$'\n#ai #art #aiart'
# Add EXTRA_TAGS to content if set and not empty
if [[ -n "$EXTRA_TAGS" ]]; then
    for TAG in "${EXTRA_TAGS[@]}"; do
        # if tag does not start with '#', add it
        if [[ $TAG != \#* ]]; then
            TAG="#$TAG"
        fi
        CONTENT+=" $TAG"
    done
fi

# Check if NSFW tag should be added
# Check if NSFW is enabled via command line or environment variable
ADD_NSFW_TAG=0
if [[ "$NSFW" -eq 1 ]]; then
    ADD_NSFW_TAG=1
    echo "NSFW flag is enabled"
fi

# Check if content contains #NSFW or #nsfw hashtag
if [[ $ADD_NSFW_TAG -eq 0 && -n "$CONTENT" ]]; then
    if echo "$CONTENT" | grep -qiE '#nsfw\b'; then
        ADD_NSFW_TAG=1
        echo "NSFW hashtag detected in content"
    fi
fi

# Extract hashtags from content and add them as tags
# Pattern: # followed by alphanumeric characters and underscores
HASHTAGS=()
SEEN_TAGS=()  # Track lowercase versions for case-insensitive deduplication

if [[ -n "$CONTENT" ]]; then
    # Extract all hashtags from content
    while IFS= read -r hashtag; do
        # Remove the leading # 
        tag_value="${hashtag#\#}"
        # Only process non-empty tags
        if [[ -n "$tag_value" ]]; then
            # Check if we already have this tag (case-insensitive)
            tag_lower="${tag_value,,}"
            found=0
            for seen_tag in "${SEEN_TAGS[@]}"; do
                if [[ "$seen_tag" == "$tag_lower" ]]; then
                    found=1
                    break
                fi
            done
            if [[ $found -eq 0 ]]; then
                HASHTAGS+=("$tag_value")
                SEEN_TAGS+=("$tag_lower")
            fi
        fi
    done < <(grep -oE '#[A-Za-z0-9_]+' <<< "$CONTENT")
fi

# Prepare hashtag arguments for nak
HASHTAG_ARGS=()
if [[ ${#HASHTAGS[@]} -gt 0 ]]; then
    echo "Found ${#HASHTAGS[@]} unique hashtag(s) in content"
    for TAG in "${HASHTAGS[@]}"; do
        HASHTAG_ARGS+=("-t" "t=$TAG")
        echo "Adding hashtag tag: t=$TAG"
    done
fi

# Create kind 1 event with nak
CMD=("nak" "event" "--auth" "--kind" "1" "--content" "$(echo -e "$CONTENT")")
if [[ ${#HASHTAG_ARGS[@]} -gt 0 ]]; then
    CMD+=("${HASHTAG_ARGS[@]}")
fi

# Add content-warning tag if NSFW is enabled or detected
if [[ $ADD_NSFW_TAG -eq 1 ]]; then
    CMD+=("-t" "content-warning=nsfw")
    echo "Adding content-warning tag for NSFW content"
fi

CMD+=("-sec" "$KEY")
# Add POW if needed
if [[ $POW_DIFF -gt 0 ]]; then
    CMD+=("--pow" "$POW_DIFF")
fi
# Add relays to the command
for RELAY in "${RELAYS[@]}"; do
    CMD+=("$RELAY")
done
# Execute the command
echo "${CMD[@]}"
"${CMD[@]}"

exit 0