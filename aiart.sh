#!/bin/bash

usage () {
    echo "Usage: $0 [file1] [file2] ... [comment]"
    echo "Uploads files to Blossom servers and creates a kind 1 event with the URLs."
    echo "Files can be specified as individual files or directories containing files."
    echo "The last argument is treated as a comment for the event."
}

# Load environment variables from ~/.nostr/girino if it exists
if [[ -f "$HOME/.nostr/tarado" ]]; then
    # shellcheck source=/dev/null
    source "$HOME/.nostr/tarado"
fi
# Default values
# Check if POW_DIFF is set, otherwise default to 20
if [[ -z "$POW_DIFF" ]]; then
    POW_DIFF=20
fi
if [[ -z "${BLOSSOMS[*]}" ]]; then
    BLOSSOMS=(
	    "https://blossom.primal.net"
	    "https://nostr.download"
	    "https://cdn.nostrcheck.me"
    )
fi
if [[ -z "$NSEC_KEY" && -z "$KEY" ]]; then
    echo "Error: Neither NSEC_KEY nor KEY is set."
    exit 1
fi

# Set default relays
DEFAULT_RELAYS=(
    "wss://relay.damus.io"
    "wss://relay.primal.net"
    "wss://nostr.girino.org"
    "wss://wot.girino.org"
    "wss://nip13.girino.org"
    "wss://nostr.oxtr.dev/"
    "wss://ditto.pub/relay"
    "wss://nostr.einundzwanzig.space/"
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

# if exists NPUB_KEY, use "nak decode | jq -r .private_key" to get it. 
# bypass decrypting
if [ -n "$DECRYPTED_KEY" ]; then
    echo "Using provided decrypted key"
    KEY="$DECRYPTED_KEY"
elif [ -n "$NSEC_KEY" ]; then
	echo "Using NSEC_KEY to decrypt the secret key"
	KEY=$(nak decode $NSEC_KEY | jq -r .private_key)
	if [ $? -ne 0 ]; then
		echo "Failed to decrypt the key"
		exit 1
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
# Parse positional and non-positional parameters using shift
while [[ $# -gt 0 ]]; do
    ARG="$1"
    case "$ARG" in
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

# Upload files to Blossom servers using nak, collect URLs
BAD_SERVERS=()
for FILE in "${FILES[@]}"; do
    UPLOADED=0
    for SERVER in "${BLOSSOM_SERVERS[@]}"; do
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
    if [[ $UPLOADED -eq 0 ]]; then
        echo "Failed to upload $FILE to any Blossom server."
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

# Extract hashtags from comment
HASHTAGS=()
if [[ -n "$CONTENT" ]]; then
    while read -r tag; do
        HASHTAGS+=("$tag")
    done < <(grep -oE '#[A-Za-z0-9_]+' <<< "$CONTENT" | sort -u)
fi

# Prepare hashtag arguments for nak
HASHTAG_ARGS=()
for TAG in "${HASHTAGS[@]}"; do
    # Remove leading '#' from tag
    TAG=${TAG:1}
    HASHTAG_ARGS+=("-t" "t=$TAG")
    echo "Adding hashtag tag: $TAG"
done

# Create kind 1 event with nak
CMD=("nak" "event" "--auth" "--kind" "1" "--content" "$(echo -e "$CONTENT")")
if [[ ${#HASHTAG_ARGS[@]} -gt 0 ]]; then
    CMD+=("${HASHTAG_ARGS[@]}")
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