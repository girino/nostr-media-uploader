#!/bin/bash

SCRIPT_DIR=$(dirname "$0")

BLOSSOMS=(
	"https://cdn.nostrcheck.me"
	"https://nostr.download"
	"https://blossom.primal.net"
)
BLOSSOM_SERVERS=()
# Shuffle the BLOSSOMS array
#BLOSSOMS=($(shuf -e "${BLOSSOMS[@]}"))

RELAYS="wss://bcast.girino.org wss://nip13.girino.org"

# functions 
# Function to delete the tempfile on exit
cleanup() {
	echo "Cleaning up..."
	if [ -n "$TEMPFILE" ] && [ -f "$TEMPFILE" ]; then
		rm -f "$TEMPFILE" && echo "Deleted tempfile $TEMPFILE"
	fi
	if [ -n "$OUT_FILE" ] && [ -f "$OUT_FILE" ]; then
		rm -f "$OUT_FILE" && echo "Deleted file $OUT_FILE"
	fi
	if [ -n "$OUT_FILE_INT" ] && [ -f "$OUT_FILE_INT" ]; then
		rm -f "$OUT_FILE_INT" && echo "Deleted file $OUT_FILE_INT"
	fi
	if [ -n "$DESC_FILE" ] && [ -f "$DESC_FILE" ]; then
		rm -f "$DESC_FILE" && echo "Deleted file $DESC_FILE"
	fi
	echo "Cleanup done."
}
trap cleanup INT TERM

die() {
	echo "$1"
	cleanup
	exit 1
}

# Function to display usage information
usage() {
	SCRIPT_NAME=$(basename "$0")
	echo "Usage: $SCRIPT_NAME [options] <file|url>... [description] [source]"
	echo
	echo "Options:"
	echo "  -h, --help        Show this help message and exit"
	echo
	echo "Arguments:"
	echo "  file|url          One or more paths to image or video files, or URLs to download videos"
	echo "  description       Optional description for the files"
	echo "  source            Optional source information to be appended to the description"
	echo
	echo "Examples:"
	echo "  $SCRIPT_NAME video.mp4"
	echo "  $SCRIPT_NAME image1.jpg image2.jpg 'This is a description'"
	echo "  $SCRIPT_NAME https://example.com/video 'Description' 'Source'"
	echo
}

to_kind_one() {
	echo "$1" | jq -c '
		.kind = 1
		| del(.id, .sig, .created_at, .pubkey)
		| .tags = [ .tags[] | select(.[0] != "nonce" and .[0] != "d") ]
		| (
			.urls = (
				[ .tags[] | select(.[0] == "imeta") | .[1:][] | select(startswith("url ")) | ltrimstr("url ") ]
			)
		)
		| .content = (
			(if (.urls | length > 0) then (.urls | join(" ") + "\n\n") else "" end)
			+ (.content // "")
		)
		| del(.urls)
	' 2>/dev/null
}

# Check if help option is provided
for arg in "$@"; do
	if [[ "$arg" == "-h" || "$arg" == "--help" ]]; then
		usage
		exit 0
	fi
done

# Check if any parameters are provided
if [ $# -eq 0 ]; then
	usage
	exit 1
fi

SCRIPT_NAME=$(basename "$0")
HISTORY_FILE="${SCRIPT_NAME%.*}.history"
HISTORY_FILE=$SCRIPT_DIR/$HISTORY_FILE
if [ ! -f "$HISTORY_FILE" ]; then
	die "History file not found: $HISTORY_FILE"
fi

# default values, override if exists in ~/.nostr/${SCRIPT_NAME%.*}
DISPLAY_SOURCE="${DISPLAY_SOURCE:-0}"
USE_KIND_ONE="${USE_KIND_ONE:-0}"
USE_OLAS="${USE_OLAS:-1}"
POW_DIFF="${POW_DIFF:-20}"
APPEND_ORIGINAL_COMMENT="${APPEND_ORIGINAL_COMMENT:-1}"
USE_COOKIES_FF="${USE_COOKIES_FF:-0}"
PROPAGATE_BLOSSOM="${PROPAGATE_BLOSSOM:-0}"

# Load environment variables from ~/.nostr/girino if it exists
if [[ -f "$HOME/.nostr/${SCRIPT_NAME%.*}" ]]; then
    # shellcheck source=/dev/null
    source "$HOME/.nostr/${SCRIPT_NAME%.*}"
else
	die "No environment variables found in ~/.nostr/${SCRIPT_NAME%.*}"
fi

# Ensure that at least one key variable is set, otherwise exit with error
if [[ -z "$NSEC_KEY" && -z "$KEY" && -z "$NCRYPT_KEY" && -z "$DECRYPTED_KEY" ]]; then
	die "Error: No key variable is set. Please set NSEC_KEY, KEY, NCRYPT_KEY, or DECRYPTED_KEY in ~/.nostr/${SCRIPT_NAME%.*}"
fi

# add EXTRA_RELAYS to RELAYS if exists
if [[ -n "${EXTRA_RELAYS[*]}" ]]; then
	for RELAY in "${EXTRA_RELAYS[@]}"; do
		RELAYS="$RELAYS $RELAY"
	done
fi

# add EXTRA_BLOSSOMS in front of BLOSSOMS if exists
if [[ -n "${EXTRA_BLOSSOMS[*]}" ]]; then
	BLOSSOMS=("${EXTRA_BLOSSOMS[@]}" "${BLOSSOMS[@]}")
fi

if [ "x$1" == "x" ]; then
	echo "needs file"
	exit 1
fi

# parse command line params
IMAGE_FILES=()
VIDEO_FILE=""
DESCRIPTION=""
SOURCE=""
CONVERT_VIDEO="${CONVERT_VIDEO:-1}"
SEND_TO_RELAY="${SEND_TO_RELAY:-1}"
DISABLE_HASH_CHECK="${DISABLE_HASH_CHECK:-0}"

while (( "$#" )); do
	PARAM="$1"
	PARAM=$(echo "$PARAM" | tr -d '\r\n\t' | sed 's/[[:space:]]\+$//')
	if [ -f "$PARAM" ]; then
		MIME_TYPE=$(file --mime-type -b "$PARAM")
		if [[ "$MIME_TYPE" == image/* ]]; then
			IMAGE_FILES+=("$PARAM")
		elif [[ "$MIME_TYPE" == video/* ]]; then
			VIDEO_FILE="$PARAM"
			# params was used, shift before breaking
			shift
			break
		else
			echo "Unsupported file type: $PARAM => $MIME_TYPE"
			exit 1
		fi
	elif [[ "$PARAM" =~ ^https?:// ]]; then
		# Remove ?utm_source=ig_web_copy_link if present at the end of the URL
		PARAM=$(echo "$PARAM" | sed 's/\?utm_source=ig_web_copy_link$//')
		VIDEO_FILE="$PARAM"
		# params was used, shift before breaking
		shift
		break
	elif [[ "$PARAM" == "--convert" || "$PARAM" == "-convert" ]]; then
		CONVERT_VIDEO=1
	elif [[ "$PARAM" == "--noconvert" || "$PARAM" == "-noconvert" ]]; then
		CONVERT_VIDEO=0
	elif [[ "$PARAM" == "--norelay" || "$PARAM" == "-norelay" ]]; then
		SEND_TO_RELAY=0
	elif [[ "$PARAM" == "--nopow" || "$PARAM" == "-nopow" ]]; then
		POW_DIFF=0
	elif [[ "$PARAM" == "--nocheck" || "$PARAM" == "-nocheck" ]]; then
		DISABLE_HASH_CHECK=1
	elif [[ "$PARAM" == "--kind1" || "$PARAM" == "-kind1" ]]; then
		USE_KIND_ONE=1
	elif [[ "$PARAM" == "--nokind1" || "$PARAM" == "-nokind1" ]]; then
		USE_KIND_ONE=0
	elif [[ "$PARAM" == "--olas" || "$PARAM" == "-olas" ]]; then
		USE_OLAS=1
	elif [[ "$PARAM" == "--noolas" || "$PARAM" == "-noolas" ]]; then
		USE_OLAS=0
	elif [[ "$PARAM" == "--comment" || "$PARAM" == "-comment" ]]; then
		APPEND_ORIGINAL_COMMENT=1
	elif [[ "$PARAM" == "--nocomment" || "$PARAM" == "-nocomment" ]]; then
		APPEND_ORIGINAL_COMMENT=0
	elif [[ "$PARAM" == "--firefox" || "$PARAM" == "-firefox" ]]; then
		USE_COOKIES_FF=1
	elif [[ "$PARAM" == "--source" || "$PARAM" == "-source" ]]; then
		DISPLAY_SOURCE=1
	elif [[ "$PARAM" == "--nosource" || "$PARAM" == "-nosource" ]]; then
		DISPLAY_SOURCE=0
	elif [[ "$PARAM" == "--password" || "$PARAM" == "-password" ]]; then
		PASSWORD="$2"
		if [ -z "$PASSWORD" ]; then
			echo "Password is required after --password option"
			exit 1
		fi
		shift  # shift to remove the password from the params
	elif [[ "$PARAM" == "--blossom" || "$PARAM" == "-blossom" ]]; then
		if [ -z "$2" ]; then
			echo "server is required after --blossom option"
			exit 1
		fi
		BLOSSOMS=("$2")
		PROPAGATE_BLOSSOM=1
		shift  # shift to remove the password from the params
	else
		# stop processing params if it's not a file or url
		# do not shift to keep the description and source

		break
	fi
	# param was used, shift
	shift
done

# Check if at least one image or video file is provided
if [ ${#IMAGE_FILES[@]} -eq 0 ] && [ -z "$VIDEO_FILE" ]; then
	echo "No image or video file provided"
	exit 1
fi

# Check if more than one video file is provided
if [ ${#IMAGE_FILES[@]} -gt 0 ] && [ -n "$VIDEO_FILE" ]; then
	echo "${#IMAGE_FILES[@]} image files and one video file provided '$VIDEO_FILE'"
	echo "Only one video file can be processed"
	exit 1
fi

# Remove processed files from the params list
NUM_IMAGE_FILES=${#IMAGE_FILES[@]}
NUM_VIDEO_FILES=0
if [ -n "$VIDEO_FILE" ]; then
	NUM_VIDEO_FILES=1
fi
# already shifted
# shift $(( NUM_IMAGE_FILES + NUM_VIDEO_FILES ))

# The remaining params are description and source
# if there is another param, its description candidate
if [ $# -gt 0 ]; then
	DESCRIPTION_CANDIDATE="$1"
	shift
fi
# if there is another param, its source candidate
if [ $# -gt 0 ]; then
	SOURCE_CANDIDATE="$1"
	shift
fi
# Check if there are remaining parameters
if [ $# -gt 0 ]; then
	echo "Too many parameters provided"
	exit 1
fi

# Check if the video file name is present in the history file
if [ -n "$VIDEO_FILE" ]; then
	TMP_VIDEO_FILE=$(echo "$VIDEO_FILE" | tr -d '\r\n')
	# remove url params from the video file but only if from instagram
	if [[ "$TMP_VIDEO_FILE" =~ ^https?://.*instagram\.com/.* ]]; then
		TMP_VIDEO_FILE=$(echo "$TMP_VIDEO_FILE" | sed 's/\?.*//')
	fi
	ORIGINAL_VIDEO_FILE="$TMP_VIDEO_FILE"
	# remove trailing "/" from VIDEO_FILE if it exists
	TMP_VIDEO_FILE=$(echo "$TMP_VIDEO_FILE" | sed 's:/*$::')
	VIDEO_FILE_NAME=$(basename "$TMP_VIDEO_FILE")
	if [ $DISABLE_HASH_CHECK -eq 0 ]; then
		if grep -q "$VIDEO_FILE_NAME" "$HISTORY_FILE"; then
			echo "Video file name already processed: $VIDEO_FILE_NAME"
			exit 1
		fi
	fi
fi

# Check if the image file names are present in the history file
for IMAGE_FILE in "${IMAGE_FILES[@]}"; do
	IMAGE_FILE_NAME=$(basename "$IMAGE_FILE")
	if [ $DISABLE_HASH_CHECK -eq 0 ]; then
		if grep -q "$IMAGE_FILE_NAME" "$HISTORY_FILE"; then
			echo "Image file name already processed: $IMAGE_FILE_NAME"
			exit 1
		fi
	fi
done

# If source is provided, append it to the description
if [ -n "$SOURCE" ]; then
	DESCRIPTION="${DESCRIPTION}"$'\n\n'"Source: $SOURCE"
fi

# if exists NPUB_KEY, use "nak decode | jq -r .private_key" to get it. 
# bypass decrypting
if [ -n "$NSEC_KEY" ]; then
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

if [ -z "$KEY" ]; then
	echo "Decryption failed, key is empty"
	exit 1
fi

# if it's an url from facebook, download the video
if [ -n "$VIDEO_FILE" ]; then
	if [[ "$VIDEO_FILE" == https://*.facebook.com/* || "$VIDEO_FILE" == https://facebook.com/* || \
			"$VIDEO_FILE" == https://*.fb.watch/* || "$VIDEO_FILE" == https://fb.watch/* || \
			"$VIDEO_FILE" == https://*.x.com/* || "$VIDEO_FILE" == https://x.com/* || \
			"$VIDEO_FILE" == https://*.threads.com/* || "$VIDEO_FILE" == https://threads.com/* || \
			"$VIDEO_FILE" == https://*.instagram.com/* || "$VIDEO_FILE" == https://instagram.com/* || \
			"$VIDEO_FILE" == https://*.tiktok.com/* || "$VIDEO_FILE" == https://tiktok.com/* || \
			"$VIDEO_FILE" == https://*.douyin.com/* || "$VIDEO_FILE" == https://douyin.com/* || \
			"$VIDEO_FILE" == https://*.bilibili.com/* || "$VIDEO_FILE" == https://bilibili.com/* || \
			"$VIDEO_FILE" == https://*.youtube.com/* || "$VIDEO_FILE" == https://youtube.com/* || \
			"$VIDEO_FILE" == https://*.youtu.be/* || "$VIDEO_FILE" == https://youtu.be/* || \
			"$VIDEO_FILE" == https://*.y2meta.com/* || "$VIDEO_FILE" == https://y2meta.com/* || \
			"$VIDEO_FILE" == https://*.y2meta.to/* || "$VIDEO_FILE" == https://y2meta.to/* || \
			"$VIDEO_FILE" == https://*.y2meta.net/* || "$VIDEO_FILE" == https://y2meta.net/* || \
			"$VIDEO_FILE" == https://*.y2meta.org/* || "$VIDEO_FILE" == https://y2meta.org/* || \
			"$VIDEO_FILE" == https://*.y2meta.io/* || "$VIDEO_FILE" == https://y2meta.io/* || \
			"$VIDEO_FILE" == https://*.y2meta.tv/* || "$VIDEO_FILE" == https://y2meta.tv/* || \
			"$VIDEO_FILE" == https://*.youtube.com/* || "$VIDEO_FILE" == https://youtube.com/* ]]; then
		# generate temp filename for file download
		FILE_BASE=$(mktemp)
		FILE_BASE_INT=$(mktemp)
		OUT_FILE_INT=${FILE_BASE_INT}.mp4
		OUT_FILE=${FILE_BASE}.mp4
		DESC_FILE=${FILE_BASE_INT}.description
		echo "Downloading reels to $OUT_FILE"
		WINFILE_INT=$(cygpath -w "$OUT_FILE_INT")
		WINFILE=$(cygpath -w "$OUT_FILE")
		FORMATS='bestvideo[codec^=hevc]+bestaudio/bestvideo[codec^=avc]+bestaudio/best[codec^=hevc]/best[codec^=avc]/bestvideo+bestaudio/best'
		if [ $CONVERT_VIDEO -eq 0 ]; then
			FORMATS='bestvideo[codec^=hevc]+bestaudio/bestvideo[codec^=avc]+bestaudio/best[codec^=hevc]/best[codec^=avc]/best'
		fi
		YT_DLP_OPTS=()
		if [ "$USE_COOKIES_FF" -eq 1 ]; then
			YT_DLP_OPTS+=(--cookies-from-browser firefox)
		fi
		/usr/local/bin/yt-dlp "${YT_DLP_OPTS[@]}" "$VIDEO_FILE" -f "$FORMATS" -S ext:mp4:m4a --merge-output-format mp4 --write-description -o "$WINFILE_INT"
		if [ $? -ne 0 ]; then
			ALT_SCRIPT="${SCRIPT_NAME%.*}img.sh"
			if [ -x "$SCRIPT_DIR/$ALT_SCRIPT" ]; then
				echo "Using alternative script $ALT_SCRIPT to download"
				ALT_OPTS=()
				if [ "$USE_COOKIES_FF" -eq 1 ]; then
					ALT_OPTS+=(-firefox)
				fi
				if [ "$PROPAGATE_BLOSSOM" -eq 1 ]; then
					ALT_OPTS+=(-blossom "${BLOSSOMS[@]}")
				fi
				if [ "$APPEND_ORIGINAL_COMMENT" -eq 0 ]; then
					ALT_OPTS+=(-nocomment)
				fi
				if [ "$DISPLAY_SOURCE" -eq 0 ]; then
					ALT_OPTS+=(-nosource)
				fi
				if [ "$SEND_TO_RELAY" -eq 0 ]; then
					ALT_OPTS+=(-norelay)
				fi
				# Add custom caption if provided
				if [ -n "$DESCRIPTION_CANDIDATE" ]; then
					echo "$SCRIPT_DIR/$ALT_SCRIPT" "${ALT_OPTS[@]}" -key "$KEY" "$VIDEO_FILE" "$DESCRIPTION_CANDIDATE"
					"$SCRIPT_DIR/$ALT_SCRIPT" "${ALT_OPTS[@]}" -key "$KEY" "$VIDEO_FILE" "$DESCRIPTION_CANDIDATE"
				else
					echo "$SCRIPT_DIR/$ALT_SCRIPT" "${ALT_OPTS[@]}" -key "$KEY" "$VIDEO_FILE"
					"$SCRIPT_DIR/$ALT_SCRIPT" "${ALT_OPTS[@]}" -key "$KEY" "$VIDEO_FILE"
				fi
				if [ $? -ne 0 ]; then
					die "Failed to download video from $VIDEO_FILE"
				fi
				exit 0
			else
				die "Failed to download video from $VIDEO_FILE"
			fi
		fi
		if [ -f "$DESC_FILE" ] && [ $APPEND_ORIGINAL_COMMENT -eq 1 ]; then
			echo "Reading description from $DESC_FILE"
			if [ -n "$DESCRIPTION_CANDIDATE" ]; then
				DESCRIPTION_CANDIDATE="$DESCRIPTION_CANDIDATE"$'\n\n'$(cat "$DESC_FILE")
			else
				DESCRIPTION_CANDIDATE=$(cat "$DESC_FILE")
			fi
			rm -f "$DESC_FILE"
		fi
		if [ -z "$SOURCE_CANDIDATE" ]; then
			SOURCE_CANDIDATE="$VIDEO_FILE"
		fi
		# Calculate the sha256 hash of the downloaded file
		DOWNLOADED_FILE_HASH=$(sha256sum "$OUT_FILE_INT" | awk '{print $1}')
		echo "SHA256 hash of the downloaded file: $DOWNLOADED_FILE_HASH"
		if grep -q "$DOWNLOADED_FILE_HASH" "$HISTORY_FILE"; then
			die "File hash already processed: $IMAGE_FILE"
		fi
		# Detect the video codec
		VIDEO_CODEC=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 "$WINFILE_INT")
		# Remove carriage return characters from the video codec
		VIDEO_CODEC=$(echo "$VIDEO_CODEC" | tr -d '\r')
		echo "Video codec: '$VIDEO_CODEC'"
		# Check if the video codec is h264 or h265
		if [ "$VIDEO_CODEC" != "h264" ] && [ "$VIDEO_CODEC" != "hevc" ]; then
			if [ $CONVERT_VIDEO -eq 1 ]; then
				echo "Converting $OUT_FILE_INT to iOS compatible format"
				# Get the average bitrate directly from the video
				BITRATE=$(ffprobe -v error -select_streams v:0 -show_entries stream=bit_rate -of csv=p=0 "$WINFILE_INT")
				# Remove carriage return from BITRATE
				BITRATE=$(echo "$BITRATE" | tr -d '\r')
				# Remove non-numeric characters from BITRATE
				BITRATE=$(echo "$BITRATE" | tr -cd '[:digit:]')
				echo "Bitrate: '$BITRATE'"

				# Check if BITRATE is a number
				if ! [[ "$BITRATE" =~ ^[0-9]+$ ]]; then
					die "Invalid bitrate: '$BITRATE'"
				fi

				# Use the calculated bitrate for the conversion
				H264_BITRATE=$((BITRATE * 2))
				ffmpeg -y -i "$WINFILE_INT" -c:v h264_qsv -b:v "${H264_BITRATE}" -preset slow -pix_fmt nv12 -movflags +faststart -c:a copy "$WINFILE"
				if [ $? -ne 0 ]; then
					echo "Failed to convert file, trying with libx265"
					H265_BITRATE=$((BITRATE * 3 / 2))
					ffmpeg -y -i "$WINFILE_INT" -c:v libx265 -b:v "${H265_BITRATE}" -preset ultrafast -c:a copy -movflags +faststart -tag:v hvc1 "$WINFILE" || die "Failed to convert file"
				fi
			else
				die "Video codec is not h264 or hevc and conversion is disabled, cannot process the file"
			fi
			VIDEO_FILE="$OUT_FILE"
		else
			VIDEO_FILE="$OUT_FILE_INT"
		fi
		echo "Downloaded reels to '$VIDEO_FILE' with description '$DESCRIPTION_CANDIDATE'"
	fi
	# at this point i need an existing file
	if [ ! -f "$VIDEO_FILE" ]; then
			echo "file does not exist"
			exit 1
	fi
fi

if [ -z "${DESCRIPTION// }" ]; then
	DESCRIPTION="$DESCRIPTION_CANDIDATE"
fi

if [ $DISPLAY_SOURCE -eq 1 ]; then
	if [ -n "$SOURCE_CANDIDATE" ]; then
		if [ -n "$DESCRIPTION" ]; then
			DESCRIPTION="${DESCRIPTION}"$'\n\n'"Source: $SOURCE_CANDIDATE"
		else
			DESCRIPTION="Source: $SOURCE_CANDIDATE"
		fi
	fi
fi

# Create an array to store file hashes
FILE_HASHES=()
if [ $DISABLE_HASH_CHECK -eq 0 ]; then
	if [ ${#IMAGE_FILES[@]} -eq 0 ]; then
		for FILE in "$OUT_FILE" "$OUT_FILE_INT"; do
			if [ -n "$FILE" ] && [ -f "$FILE" ]; then
				# Calculate file hash
				FILE_HASH=$(sha256sum "$FILE" | awk '{print $1}')
				# Check if file hash exists in history file
				if grep -q "$FILE_HASH" "$HISTORY_FILE"; then
					die "File hash already processed: $FILE"
				fi
				FILE_HASHES+=("$FILE_HASH")
			fi
		done 
	else
		# If there are additional image files, process them
		for IMAGE_FILE in "${IMAGE_FILES[@]}"; do
			# Calculate file hash
			FILE_HASH=$(sha256sum "$IMAGE_FILE" | awk '{print $1}')
			# Check if file hash exists in history file
			if grep -q "$FILE_HASH" "$HISTORY_FILE"; then
				die "File hash already processed: $IMAGE_FILE"
			fi
			# Add file hash to the array
			FILE_HASHES+=("$FILE_HASH")
		done
	fi
fi
# file type already checked, just check if the file array is empty
TEMPFILE=$(mktemp)
WINTEMP=$(cygpath -w "$TEMPFILE")

# Write the relays to the tempfile in JSON format
echo -n '[' > "$TEMPFILE"
for RELAY in $RELAYS; do
	echo -n "\"$RELAY\"," >> "$TEMPFILE"
done
# Remove the last comma and close the JSON array
sed -i '$ s/,$//' "$TEMPFILE"
echo ']' >> "$TEMPFILE"

USE_LEGACY=0
WINFILES=()
if [ ${#IMAGE_FILES[@]} -gt 0 ]; then
	CLI_TOOL="nip68-cli"
	for IMAGE_FILE in "${IMAGE_FILES[@]}"; do
		IMAGE_FILE_WIN=$(cygpath -w "$IMAGE_FILE")
		WINFILES+=("$IMAGE_FILE_WIN")
	done
else
	CLI_TOOL="nip71-cli"
	USE_LEGACY=1
	WINFILES+=("$(cygpath -w "$VIDEO_FILE")")
fi

CMD=("$CLI_TOOL")
# for FILE in "${WINFILES[@]}"; do
#     CMD+=("-file" "$FILE")
# done
CMD+=("-key" "$KEY")
if [ "$SEND_TO_RELAY" -eq 1 ]; then
	# only send to relays if its for olas.
	if [ $USE_OLAS -eq 1 ]; then
		CMD+=("-r" "$WINTEMP")
	fi
fi
if [ "x$DESCRIPTION" != "x" ]; then
	CMD+=("-description" "$DESCRIPTION")
fi
# force pow to zero on nopow
CMD+=("-diff" "$POW_DIFF")

RESULT=0
for TRIES in "${!BLOSSOMS[@]}"; do
	BLOSSOM="${BLOSSOMS[$TRIES]}"
	echo "Using blossom: $BLOSSOM, try: $((TRIES+1))"
	for FILE in "${WINFILES[@]}"; do
		upload_output=$(nak blossom upload --server "$BLOSSOM" "$FILE" "--sec" "$KEY")
		RESULT=$?
		if [ $RESULT -ne 0 ] ; then
			echo "Failed to upload file $FILE to $BLOSSOM with nak, trying with blossom-cli"
			upload_output=$(blossom-cli upload -file "$FILE" -server "$BLOSSOM" -privkey "$KEY")
			RESULT=$?
		fi
		if [ $RESULT -ne 0 ]; then
			echo "Failed to upload file $FILE to $BLOSSOM: $upload_output"
			upload_success=0
			break
		fi
		upload_success=1
		file_url=$(echo "$upload_output" | jq -r '.url')
		CMD+=("-url" "$file_url")
	done

	if [ $upload_success -eq 0 ]; then
		RESULT=1
		continue
	fi

	FULL_CMD=("${CMD[@]}")
	#FULL_CMD+=("-blossom" "$BLOSSOM")
	# only use legacy for videos
	if [ $USE_LEGACY -eq 1 ]; then
		FULL_CMD+=("-legacy")
	fi
	echo "${FULL_CMD[@]}"
	OUTPUT=$("${FULL_CMD[@]}")
	RESULT=$?
	echo "$OUTPUT"
	# if [ $USE_LEGACY -eq 1 ] && [ $RESULT -eq 0 ]; then
	# 	FULL_CMD+=("-legacy")
	# 	echo "${FULL_CMD[@]}"
	# 	"${FULL_CMD[@]}"
	# 	RESULT=$?
	# fi
	# use nak to publish KIND_ONE to all relays
	if [ $USE_KIND_ONE -eq 1 ] && [ $RESULT -eq 0 ]; then
		# Extract the event JSON from the output
		EVENT_JSON="${OUTPUT#*\{}"
		EVENT_JSON="${EVENT_JSON%%$'\n'*}"
		EVENT_JSON="{${EVENT_JSON}"
		KIND_ONE=$(to_kind_one "$EVENT_JSON") || die "Failed to convert to KIND_ONE"
		if [ "$SEND_TO_RELAY" -eq 1 ]; then
			echo "Publishing KIND_ONE to relays"
			echo "$KIND_ONE" | nak event "--auth" -sec "$KEY" --pow "$POW_DIFF" $RELAYS
		else
			echo "$KIND_ONE" | nak event -sec "$KEY" --pow "$POW_DIFF"
		fi
	fi
	if [ $RESULT -eq 0 ]; then
		break
	fi
done

if [ $RESULT -ne 0 ]; then
	die "Failed to process the file '$WINFILE' with $CLI_TOOL"
fi

# Add the file hash to history file only if the CLI_TOOL command was successful
# but only if sent to relays
if [ "$SEND_TO_RELAY" -eq 1 ] && [ "$DISABLE_HASH_CHECK" -eq 0 ]; then
	for FILE_HASH in "${FILE_HASHES[@]}"; do
		echo "$FILE_HASH" >> "$HISTORY_FILE"
	done
	if [ -n "$ORIGINAL_VIDEO_FILE" ]; then
		echo "$ORIGINAL_VIDEO_FILE" >> "$HISTORY_FILE"
	fi
	for IMAGE_FILE in "${IMAGE_FILES[@]}"; do
		echo "$IMAGE_FILE" >> "$HISTORY_FILE"
	done
fi

# Remove the tempfile
cleanup
