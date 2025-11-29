#!/bin/bash

SCRIPT_DIR=$(dirname "$0")

BLOSSOMS=(
	"https://cdn.nostrcheck.me"
	"https://nostr.download"
	"https://blossom.primal.net"
)
# Shuffle the BLOSSOMS array (disabled temporarily until finished)
#BLOSSOMS=($(shuf -e "${BLOSSOMS[@]}"))

RELAYS="wss://bcast.girino.org wss://nip13.girino.org"

# Global array to track files/directories for cleanup (used only by add_to_cleanup and cleanup functions)
CLEANUP_FILES=()

# functions 
# Function to add a file or directory to the cleanup list
# Parameters:
#   $1: FILE_OR_DIR - path to file or directory to add to cleanup list
add_to_cleanup() {
	local FILE_OR_DIR="$1"
	if [ -n "$FILE_OR_DIR" ]; then
		CLEANUP_FILES+=("$FILE_OR_DIR")
	fi
}

# Function to delete temp files on exit
cleanup() {
	echo "Cleaning up..."
	# Clean up all files/directories listed in the cleanup array
	for CLEANUP_ITEM in "${CLEANUP_FILES[@]}"; do
		if [ -n "$CLEANUP_ITEM" ]; then
			if [ -f "$CLEANUP_ITEM" ]; then
				rm -f "$CLEANUP_ITEM" && echo "Deleted temp file $CLEANUP_ITEM"
			elif [ -d "$CLEANUP_ITEM" ]; then
				rm -rf "$CLEANUP_ITEM" && echo "Deleted temp directory $CLEANUP_ITEM"
			fi
		fi
	done
	# Clean up temp directories (fallback for any missed ones)
	local CLEANUP_PATTERNS=("gallery_dl_*" "video_dl_*")
	for PATTERN in "${CLEANUP_PATTERNS[@]}"; do
		for TMP_DIR in /tmp/$PATTERN; do
			if [ -d "$TMP_DIR" ]; then
				rm -rf "$TMP_DIR" && echo "Deleted temp directory $TMP_DIR"
			fi
		done
	done
	echo "Cleanup done."
}
trap cleanup INT TERM

die() {
	echo "$1"
	cleanup
	exit 1
}

# Function to build caption from description candidate and extracted content
# Parameters:
#   $1: DESCRIPTION_CANDIDATE - current description candidate
#   $2: EXTRACTED_CAPTION - caption extracted from metadata/description file
#   $3: APPEND_ORIGINAL_COMMENT - 1 to append, 0 otherwise
# Returns caption via stdout
build_caption() {
	local DESCRIPTION_CANDIDATE="$1"
	local EXTRACTED_CAPTION="$2"
	local APPEND_ORIGINAL_COMMENT="$3"
	
	local file_caption=""
	if [ -n "$EXTRACTED_CAPTION" ] && [ "$APPEND_ORIGINAL_COMMENT" -eq 1 ]; then
		if [ -n "$DESCRIPTION_CANDIDATE" ]; then
			file_caption="${DESCRIPTION_CANDIDATE}"$'\n\n'"${EXTRACTED_CAPTION}"
		else
			file_caption="${EXTRACTED_CAPTION}"
		fi
	elif [ -n "$DESCRIPTION_CANDIDATE" ]; then
		file_caption="$DESCRIPTION_CANDIDATE"
	fi
	echo "$file_caption"
}

# Function to check if hash/filename exists in history file
# Parameters:
#   $1: HASH_OR_NAME - hash or filename to check
#   $2: HISTORY_FILE - path to history file
#   $3: DISABLE_HASH_CHECK - 1 to disable, 0 otherwise
# Returns 0 if found (should die), 1 if not found (ok to proceed)
check_history() {
	local HASH_OR_NAME="$1"
	local HISTORY_FILE="$2"
	local DISABLE_HASH_CHECK="$3"
	
	if [ "$DISABLE_HASH_CHECK" -eq 0 ]; then
		if grep -q "$HASH_OR_NAME" "$HISTORY_FILE"; then
			return 0  # Found - should die
		fi
	fi
	return 1  # Not found - ok to proceed
}

# Function to count files in a gallery starting from given index
# Parameters:
#   $1: START_IDX - starting index
#   $2: GALLERY_ID - gallery ID to match
#   $3: FILE_GALLERIES - array reference (passed as string to eval)
#   $4: MAX_IDX - maximum index to check
# Returns count via stdout
count_gallery_files() {
	local START_IDX="$1"
	local GALLERY_ID="$2"
	local FILE_GALLERIES_STR="$3"
	local MAX_IDX="$4"
	
	local FILE_GALLERIES=()
	eval "FILE_GALLERIES=($FILE_GALLERIES_STR)"
	
	local count=0
	for check_idx in $(seq $START_IDX $MAX_IDX); do
		local check_gallery=""
		if [ $check_idx -lt ${#FILE_GALLERIES[@]} ]; then
			check_gallery="${FILE_GALLERIES[$check_idx]}"
		fi
		if [ "$check_gallery" = "$GALLERY_ID" ]; then
			((count++))
		else
			break
		fi
	done
	echo "$count"
}

# Function to write items to history file
# Parameters:
#   $1: HISTORY_FILE - path to history file
#   $2: ITEMS - array of items to write (passed as string to eval)
write_to_history() {
	local HISTORY_FILE="$1"
	local ITEMS_STR="$2"
	
	local ITEMS=()
	eval "ITEMS=($ITEMS_STR)"
	
	for item in "${ITEMS[@]}"; do
		echo "$item" >> "$HISTORY_FILE"
	done
}

# Function to serialize an array for passing to functions
# Parameters:
#   $@ - array elements to serialize
# Returns: serialized array string via stdout (suitable for eval)
# Note: This function properly quotes array elements for safe serialization
serialize_array() {
	printf '%q ' "$@"
}

# Function to get sorted files from a directory
# Parameters:
#   $1: DIRECTORY - directory path to list files from
# Returns: array of sorted filenames via stdout (suitable for array assignment)
# Note: Sorts files numerically (version sort) and handles errors gracefully
get_sorted_files() {
	local DIRECTORY="$1"
	if [ -d "$DIRECTORY" ]; then
		ls "$DIRECTORY" 2>/dev/null | sort -V
	fi
}

# Function to wait for a file to appear
# Parameters:
#   $1: FILE - path to file to wait for
#   $2: MAX_WAIT - maximum number of wait iterations (default: 20)
# Returns: 0 if file exists, 1 if timeout
# Note: Waits up to MAX_WAIT * 0.1 seconds for file to appear
wait_for_file() {
	local file="$1"
	local MAX_WAIT="${2:-20}"
	
	local wait_count=0
	while [ $wait_count -lt "$MAX_WAIT" ] && [ ! -f "$file" ]; do
		sleep 0.1
		((wait_count++))
	done
	
	if [ -f "$file" ]; then
		return 0
	else
		return 1
	fi
}

# Function to clean URL by removing common tracking parameters
# Parameters:
#   $1: URL - URL to clean
# Returns: cleaned URL via stdout
# Note: Removes utm_source=ig_web_copy_link and other common tracking params
clean_url() {
	local URL="$1"
	# Remove ?utm_source=ig_web_copy_link if present at the end
	URL=$(echo "$URL" | sed 's/\?utm_source=ig_web_copy_link$//')
	echo "$URL"
}

# Function to extract 'id' field from JSON metadata file (for matching)
# Parameters:
#   $1: META_FILE - path to JSON metadata file
# Returns: ID via stdout, returns 0 if found, 1 if not found or error
# Note: Only extracts 'id' field to avoid matching on other ID fields
extract_meta_id_only() {
	local META_FILE="$1"
	
	if [ ! -f "$META_FILE" ]; then
		return 1
	fi
	
	local meta_id=$(jq -r '.id // empty' "$META_FILE" 2>/dev/null)
	if [ -n "$meta_id" ] && [ "$meta_id" != "null" ] && [ "$meta_id" != "empty" ]; then
		echo "$meta_id"
		return 0
	fi
	
	return 1
}

# Function to extract ID from JSON metadata file with fallbacks (for display)
# Parameters:
#   $1: META_FILE - path to JSON metadata file
# Returns: ID via stdout, returns 0 if found, 1 if not found or error
# Note: Tries multiple methods to find any ID for display purposes
extract_meta_id() {
	local META_FILE="$1"
	
	if [ ! -f "$META_FILE" ]; then
		return 1
	fi
	
	local meta_id=""
	
	# Try 'id' field first
	meta_id=$(jq -r '.id // empty' "$META_FILE" 2>/dev/null)
	if [ -n "$meta_id" ] && [ "$meta_id" != "null" ] && [ "$meta_id" != "empty" ]; then
		echo "$meta_id"
		return 0
	fi
	
	# Fallback: try 'fbid' field
	meta_id=$(jq -r '.fbid // empty' "$META_FILE" 2>/dev/null)
	if [ -n "$meta_id" ] && [ "$meta_id" != "null" ] && [ "$meta_id" != "empty" ]; then
		echo "$meta_id"
		return 0
	fi
	
	# Fallback: try extracting from 'url' field
	local url=$(jq -r '.url // empty' "$META_FILE" 2>/dev/null)
	if [ -n "$url" ] && [ "$url" != "null" ] && [ "$url" != "empty" ]; then
		meta_id=$(echo "$url" | grep -oE '[?&]fbid=([0-9]+)' | grep -oE '[0-9]+' | head -1)
		if [ -n "$meta_id" ]; then
			echo "$meta_id"
			return 0
		fi
	fi
	
	# Fallback: grep for fbid patterns in the JSON
	meta_id=$(grep -oE '[?&]fbid=([0-9]+)' "$META_FILE" 2>/dev/null | grep -oE '[0-9]+' | head -1)
	if [ -n "$meta_id" ]; then
		echo "$meta_id"
		return 0
	fi
	
	meta_id=$(grep -oE 'fbid["\s:=]+([0-9]+)' "$META_FILE" 2>/dev/null | grep -oE '[0-9]+' | head -1)
	if [ -n "$meta_id" ]; then
		echo "$meta_id"
		return 0
	fi
	
	return 1
}

# Function to get first non-empty caption from an array of captions
# Parameters:
#   $1: CAPTIONS_STR - array of captions passed as string to eval
# Returns: first non-empty caption via stdout, or empty if none found
get_first_non_empty_caption() {
	local CAPTIONS_STR="$1"
	local CAPTIONS=()
	eval "CAPTIONS=($CAPTIONS_STR)"
	
	local gallery_caption=""
	if [ ${#CAPTIONS[@]} -gt 0 ]; then
		# Use first non-empty caption, or first caption if all empty
		for cap in "${CAPTIONS[@]}"; do
			if [ -n "$cap" ]; then
				gallery_caption="$cap"
				break
			fi
		done
		if [ -z "$gallery_caption" ] && [ -n "${CAPTIONS[0]}" ]; then
			gallery_caption="${CAPTIONS[0]}"
		fi
	fi
	echo "$gallery_caption"
}

# Function to wait for metadata file to appear
# Parameters:
#   $1: FILE - path to image file
#   $2: MAX_WAIT - maximum number of wait iterations (default: 10)
# Returns: metadata file path via stdout if found, empty if timeout
# Note: Waits up to MAX_WAIT * 0.1 seconds for metadata file to appear
#       Uses wait_for_file() internally to wait for metadata file
wait_for_metadata_file() {
	local file="$1"
	local MAX_WAIT="${2:-10}"
	
	if [ ! -f "$file" ]; then
		return 1
	fi
	
	# Use the standard metadata file pattern
	local meta="${file}.json"
	
	# Use wait_for_file() to wait for metadata file to appear
	if wait_for_file "$meta" "$MAX_WAIT"; then
		echo "$meta"
		return 0
	fi
	
	return 1
}

# Function to build event content for kind 1 Nostr event
# Parameters:
#   $1: UPLOAD_URLS_STR - array of uploaded URLs passed as string to eval
#   $2: FILE_CAPTIONS_STR - array of captions passed as string to eval
#   $3: FILE_GALLERIES_STR - array of gallery IDs passed as string to eval
#   $4: FILE_SOURCES_STR - array of source URLs passed as string to eval
#   $5: DISPLAY_SOURCE - 1 to display sources, 0 otherwise
# Returns: event content via stdout
# Note: Interleaves URLs and captions, handles galleries, adds sources at bottom
build_event_content() {
	local UPLOAD_URLS_STR="$1"
	local FILE_CAPTIONS_STR="$2"
	local FILE_GALLERIES_STR="$3"
	local FILE_SOURCES_STR="$4"
	local DISPLAY_SOURCE="$5"
	
	local UPLOAD_URLS=()
	local FILE_CAPTIONS=()
	local FILE_GALLERIES=()
	local FILE_SOURCES=()
	eval "UPLOAD_URLS=($UPLOAD_URLS_STR)"
	eval "FILE_CAPTIONS=($FILE_CAPTIONS_STR)"
	eval "FILE_GALLERIES=($FILE_GALLERIES_STR)"
	eval "FILE_SOURCES=($FILE_SOURCES_STR)"
	
	local CONTENT=""
	
	# Interleave URLs and captions
	if [ ${#UPLOAD_URLS[@]} -gt 0 ]; then
		local idx=0
		local current_gallery_id=""
		local gallery_caption=""
		local gallery_count=0
		local last_idx_in_gallery=-1
		local need_space_before_url=0  # Track if we need spacing before adding next URL
		
		while [ $idx -lt ${#UPLOAD_URLS[@]} ]; do
			local url="${UPLOAD_URLS[$idx]}"
			local gallery_id=""
			if [ $idx -lt ${#FILE_GALLERIES[@]} ]; then
				gallery_id="${FILE_GALLERIES[$idx]}"
			fi
			
			# Check if this is a new gallery (and not the first item)
			if [ -n "$current_gallery_id" ] && [ "$gallery_id" != "$current_gallery_id" ]; then
				# End of previous gallery - add its caption if available (multi-image gallery)
				# Note: This should have been handled when we processed the last item of the previous gallery
				# But if we missed it, handle it here
				if [ $gallery_count -gt 1 ] && [ -n "$gallery_caption" ]; then
					# Empty line after images, before caption
					CONTENT="${CONTENT}"$'\n'"${gallery_caption}"
					need_space_before_url=1  # Need 2 empty lines after caption before next URL
				fi
				gallery_caption=""
				gallery_count=0
				last_idx_in_gallery=-1
			fi
			
			# Check if this is start of a new gallery or a single file
			if [ "$current_gallery_id" != "$gallery_id" ]; then
				current_gallery_id="$gallery_id"
				# Count how many files belong to this gallery
				local FILE_GALLERIES_FOR_COUNT_STR=$(serialize_array "${FILE_GALLERIES[@]}")
				gallery_count=$(count_gallery_files "$idx" "$gallery_id" "$FILE_GALLERIES_FOR_COUNT_STR" "$((${#UPLOAD_URLS[@]} - 1))")
				last_idx_in_gallery=$((idx + gallery_count - 1))
				
				# If multiple files in gallery, collect all captions
				if [ $gallery_count -gt 1 ]; then
					# Accumulate all captions from all files in the gallery
					gallery_caption=""
					local caption_count=0
					for cap_idx in $(seq $idx $last_idx_in_gallery); do
						if [ $cap_idx -lt ${#FILE_CAPTIONS[@]} ] && [ -n "${FILE_CAPTIONS[$cap_idx]}" ]; then
							if [ $caption_count -eq 0 ]; then
								gallery_caption="${FILE_CAPTIONS[$cap_idx]}"
							else
								# Add blank line between captions (two newlines = one blank line)
								gallery_caption="${gallery_caption}"$'\n\n'"${FILE_CAPTIONS[$cap_idx]}"
							fi
							((caption_count++))
						fi
					done
				else
					# Single file - caption goes immediately after URL
					gallery_caption=""
				fi
			fi
			
			# Add spacing before URL if needed (2 empty lines after previous caption)
			# Three newlines = caption + newline + empty line + empty line + URL
			if [ $need_space_before_url -eq 1 ]; then
				CONTENT="${CONTENT}"$'\n\n\n'
				need_space_before_url=0
			fi
			
			# Add URL
			if [ -n "$CONTENT" ]; then
				CONTENT="${CONTENT}"$'\n'"${url}"
			else
				CONTENT="${url}"
			fi
			
			# Check if we're at the last item in a gallery - add caption after all gallery URLs
			if [ $gallery_count -gt 1 ] && [ $idx -eq $last_idx_in_gallery ]; then
				# This is the last URL in the gallery
				# Check if there's a next item - we'll need spacing before it
				if [ $((idx + 1)) -lt ${#UPLOAD_URLS[@]} ]; then
					if [ -n "$gallery_caption" ]; then
						# Empty line after images, before caption (two newlines = one empty line)
						CONTENT="${CONTENT}"$'\n\n'"${gallery_caption}"
						need_space_before_url=1  # Need 2 empty lines after caption before next URL
					else
						# No caption, but still need 2 empty lines before next URL
						need_space_before_url=1
					fi
				else
					# No next item, just add caption if available
					if [ -n "$gallery_caption" ]; then
						# Empty line after images, before caption (two newlines = one empty line)
						CONTENT="${CONTENT}"$'\n\n'"${gallery_caption}"
					fi
				fi
			fi
			
			# For single files (not galleries), add caption immediately after URL
			if [ $gallery_count -eq 1 ]; then
				if [ $idx -lt ${#FILE_CAPTIONS[@]} ] && [ -n "${FILE_CAPTIONS[$idx]}" ]; then
					# Empty line after URL, before caption (two newlines = one empty line)
					CONTENT="${CONTENT}"$'\n\n'"${FILE_CAPTIONS[$idx]}"
					# Check if there's a next item
					if [ $((idx + 1)) -lt ${#UPLOAD_URLS[@]} ]; then
						need_space_before_url=1  # Need 2 empty lines after caption before next URL
					fi
				fi
			fi
			
			((idx++))
		done
	fi
	
	# Add sources at the bottom (if any and if display_source is enabled)
	if [ $DISPLAY_SOURCE -eq 1 ] && [ ${#FILE_SOURCES[@]} -gt 0 ]; then
		if [ -n "$CONTENT" ]; then
			# One empty line before sources section (two newlines = one empty line)
			CONTENT="${CONTENT}"$'\n\n'
		fi
		
		# Count non-empty sources
		local source_count=0
		for source in "${FILE_SOURCES[@]}"; do
			if [ -n "$source" ]; then
				((source_count++))
			fi
		done
		
		if [ $source_count -eq 1 ]; then
			# Only one source - use "Source: " prefix on same line
			for source in "${FILE_SOURCES[@]}"; do
				if [ -n "$source" ]; then
					CONTENT="${CONTENT}Source: ${source}"
					break
				fi
			done
		else
			# Multiple sources - use "Sources:" on its own line, then each source with "- " prefix
			CONTENT="${CONTENT}Sources:"
			for source in "${FILE_SOURCES[@]}"; do
				if [ -n "$source" ]; then
					CONTENT="${CONTENT}"$'\n'"- ${source}"
				fi
			done
		fi
	fi
	
	echo "$CONTENT"
}

# Function to check a file for matching FBID in metadata
# Parameters:
#   $1: FILE - path to image file to check
#   $2: FBID - Facebook ID to match against
# Returns: position number via stdout if found, returns 0 if found, 1 if not found or error
check_file_for_fbid() {
	local file="$1"
	local FBID="$2"
	
	# Skip metadata files
	[[ "$file" == *.json ]] && return 1
	
	# Extract position number from filename (e.g., "1.jpg" -> 1, "2.png" -> 2)
	local basename=$(basename "$file")
	local position=${basename%%.*}
	# Verify it's a number
	if ! [[ "$position" =~ ^[0-9]+$ ]]; then
		return 1
	fi
	
	# Wait for metadata file to appear and get its path
	local meta=$(wait_for_metadata_file "$file" 10)
	
	# Check metadata file if it exists
	if [ -n "$meta" ] && [ -f "$meta" ]; then
		# Check if the 'id' field matches the FBID (only check 'id' field, not other ID fields)
		local meta_id=$(extract_meta_id_only "$meta")
		if [ $? -eq 0 ] && [ "$meta_id" = "$FBID" ]; then
			echo "$position"
			return 0
		fi
	fi
	
	return 1
}

# Function to download video from URL using yt-dlp
# Parameters:
#   $1: VIDEO_URL - URL to download
#   $2: HISTORY_FILE - path to history file
#   $3: CONVERT_VIDEO - 1 to convert, 0 otherwise
#   $4: USE_COOKIES_FF - 1 to use Firefox cookies, 0 otherwise
#   $5: APPEND_ORIGINAL_COMMENT - 1 to append, 0 otherwise
#   $6: DISABLE_HASH_CHECK - 1 to disable, 0 otherwise
#   $7: DESCRIPTION_CANDIDATE - current description candidate
#   $8: SOURCE_CANDIDATE - current source candidate
# Return variables (set at end of function):
#   download_video_ret_files - array of downloaded files
#   download_video_ret_captions - array of captions (one per file, empty string if no caption)
#   download_video_ret_source - source to set (empty if should keep current)
#   download_video_ret_success - 0 on success, 1 on failure
download_video() {
	local VIDEO_URL="$1"
	local HISTORY_FILE="$2"
	local CONVERT_VIDEO="$3"
	local USE_COOKIES_FF="$4"
	local APPEND_ORIGINAL_COMMENT="$5"
	local DISABLE_HASH_CHECK="$6"
	local DESCRIPTION_CANDIDATE="$7"
	local SOURCE_CANDIDATE="$8"
	
	local DOWNLOADED=0
	# Return variables (global, set at end of function)
	download_video_ret_files=()
	download_video_ret_captions=()
	download_video_ret_source=""
	download_video_ret_success=1
	
	# Create a temporary directory for video downloads
	local VIDEO_TMPDIR=$(mktemp -d /tmp/video_dl_XXXXXXXX)
	# Add temp directory to cleanup list
	add_to_cleanup "$VIDEO_TMPDIR"
	
	local OUT_FILE_INT="${VIDEO_TMPDIR}/video.mp4"
	local OUT_FILE="${VIDEO_TMPDIR}/video_converted.mp4"
	local DESC_FILE="${VIDEO_TMPDIR}/video.description"
	
	# Also add individual files for redundancy (directory cleanup + individual file cleanup)
	add_to_cleanup "$OUT_FILE_INT"
	add_to_cleanup "$OUT_FILE"
	add_to_cleanup "$DESC_FILE"
	
	echo "Attempting to download as video to $OUT_FILE_INT"
	local WINFILE_INT=$(cygpath -w "$OUT_FILE_INT")
	local WINFILE=$(cygpath -w "$OUT_FILE")
	
	local FORMATS='bestvideo[codec^=hevc]+bestaudio/bestvideo[codec^=avc]+bestaudio/best[codec^=hevc]/best[codec^=avc]/bestvideo+bestaudio/best'
	if [ "$CONVERT_VIDEO" -eq 0 ]; then
		FORMATS='bestvideo[codec^=hevc]+bestaudio/bestvideo[codec^=avc]+bestaudio/best[codec^=hevc]/best[codec^=avc]/best'
	fi
	
	local YT_DLP_OPTS=()
	if [ "$USE_COOKIES_FF" -eq 1 ]; then
		YT_DLP_OPTS+=(--cookies-from-browser firefox)
	fi
	
	/usr/local/bin/yt-dlp "${YT_DLP_OPTS[@]}" "$VIDEO_URL" -f "$FORMATS" -S ext:mp4:m4a --merge-output-format mp4 --write-description -o "$WINFILE_INT" 2>/dev/null
	
	if [ $? -eq 0 ] && [ -f "$OUT_FILE_INT" ]; then
		DOWNLOADED=1
		local file_caption=""
		local extracted_caption=""
		if [ -f "$DESC_FILE" ] && [ "$APPEND_ORIGINAL_COMMENT" -eq 1 ]; then
			echo "Reading description from $DESC_FILE"
			extracted_caption=$(cat "$DESC_FILE")
		fi
		file_caption=$(build_caption "$DESCRIPTION_CANDIDATE" "$extracted_caption" "$APPEND_ORIGINAL_COMMENT")
		
		if [ -z "$SOURCE_CANDIDATE" ]; then
			download_video_ret_source="$VIDEO_URL"
		fi
		
		# Calculate the sha256 hash
		local DOWNLOADED_FILE_HASH=$(sha256sum "$OUT_FILE_INT" | awk '{print $1}')
		echo "SHA256 hash: $DOWNLOADED_FILE_HASH"
		if check_history "$DOWNLOADED_FILE_HASH" "$HISTORY_FILE" "$DISABLE_HASH_CHECK"; then
			die "File hash already processed: $DOWNLOADED_FILE_HASH"
		fi
		
		# Detect and convert video codec if needed
		local VIDEO_CODEC=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 "$WINFILE_INT" 2>/dev/null)
		VIDEO_CODEC=$(echo "$VIDEO_CODEC" | tr -d '\r')
		echo "Video codec: '$VIDEO_CODEC'"
		
		if [ "$VIDEO_CODEC" != "h264" ] && [ "$VIDEO_CODEC" != "hevc" ]; then
			if [ "$CONVERT_VIDEO" -eq 1 ]; then
				echo "Converting $OUT_FILE_INT to iOS compatible format"
				local BITRATE=$(ffprobe -v error -select_streams v:0 -show_entries stream=bit_rate -of csv=p=0 "$WINFILE_INT" 2>/dev/null)
				BITRATE=$(echo "$BITRATE" | tr -d '\r' | tr -cd '[:digit:]')
				echo "Bitrate: '$BITRATE'"
				
				if [[ "$BITRATE" =~ ^[0-9]+$ ]]; then
					local H264_BITRATE=$((BITRATE * 2))
					ffmpeg -y -i "$WINFILE_INT" -c:v h264_qsv -b:v "${H264_BITRATE}" -preset slow -pix_fmt nv12 -movflags +faststart -c:a copy "$WINFILE" 2>/dev/null
					if [ $? -ne 0 ]; then
						local H265_BITRATE=$((BITRATE * 3 / 2))
						ffmpeg -y -i "$WINFILE_INT" -c:v libx265 -b:v "${H265_BITRATE}" -preset ultrafast -c:a copy -movflags +faststart -tag:v hvc1 "$WINFILE" 2>/dev/null
					fi
					if [ -f "$OUT_FILE" ]; then
						download_video_ret_files+=("$OUT_FILE")
						download_video_ret_captions+=("$file_caption")
					else
						download_video_ret_files+=("$OUT_FILE_INT")
						download_video_ret_captions+=("$file_caption")
					fi
				else
					download_video_ret_files+=("$OUT_FILE_INT")
					download_video_ret_captions+=("$file_caption")
				fi
			else
				die "Video codec is not h264 or hevc and conversion is disabled"
			fi
		else
			download_video_ret_files+=("$OUT_FILE_INT")
			download_video_ret_captions+=("$file_caption")
		fi
		echo "Downloaded as video: '${download_video_ret_files[-1]}'"
		download_video_ret_success=0
	fi
}

# Function to download images from URL using gallery-dl
# Parameters:
#   $1: IMAGE_URL - URL to download
#   $2: GALLERY_DL_PARAMS - array of gallery-dl parameters (passed as string to eval)
#   $3: APPEND_ORIGINAL_COMMENT - 1 to append, 0 otherwise
#   $4: DESCRIPTION_CANDIDATE - current description candidate
#   $5: SOURCE_CANDIDATE - current source candidate
#   $6: MAX_FILE_SEARCH - maximum number of files to search when looking for FBID
# Return variables (set at end of function):
#   download_images_ret_files - array of downloaded files
#   download_images_ret_captions - array of captions (one per file, empty string if no caption)
#   download_images_ret_source - source to set (empty if should keep current)
#   download_images_ret_success - 0 on success, 1 on failure
#   download_images_ret_error - error message if download failed (empty on success)
#   download_images_ret_temp_dir - temporary directory that needs cleanup (empty if none, added to cleanup list by caller)
download_images() {
	local IMAGE_URL="$1"
	local GALLERY_DL_PARAMS_STR="$2"
	local APPEND_ORIGINAL_COMMENT="$3"
	local DESCRIPTION_CANDIDATE="$4"
	local SOURCE_CANDIDATE="$5"
	local MAX_FILE_SEARCH="$6"
	
	local DOWNLOADED=0
	# Return variables (global, set at end of function)
	download_images_ret_files=()
	download_images_ret_captions=()
	download_images_ret_source=""
	download_images_ret_success=1
	download_images_ret_error=""
	download_images_ret_temp_dir=""
	
	# Reconstruct GALLERY_DL_PARAMS array from string
	local GALLERY_DL_PARAMS=()
	eval "GALLERY_DL_PARAMS=($GALLERY_DL_PARAMS_STR)"
	
	# Create a local copy of GALLERY_DL_PARAMS for modifications
	local URL_GALLERY_DL_PARAMS=("${GALLERY_DL_PARAMS[@]}")
	local PROCESSED_URL="$IMAGE_URL"
	local PRE_DOWNLOADED_DIR=""
	
	# Handle Facebook URLs - remove set parameter or infer position
	if [[ "$PROCESSED_URL" =~ facebook\.com ]]; then
		# Check if URL has set=a.XXXX or set=gm.XXXX parameter
		if [[ "$PROCESSED_URL" =~ [?\&](set=a\.[0-9]+|set=gm\.[0-9]+) ]]; then
			# First try removing the set param
			local URL_NOSET=$(echo "$PROCESSED_URL" | sed -E 's/[?&]set=a\.[0-9]+//')
			URL_NOSET=$(echo "$URL_NOSET" | sed -E 's/[?&]set=gm\.[0-9]+//')
			# Try downloading to see if it works
			echo "Trying to remove set param, new URL: $URL_NOSET"
			local TEST_TMPDIR=$(mktemp -d /tmp/gallery_dl_test_XXXXXXXX)
			local WIN_TEST_TMPDIR=$(cygpath -w "$TEST_TMPDIR")
			echo "Testing download: gallery-dl \"${URL_GALLERY_DL_PARAMS[@]}\" -f '{num}.{extension}' -D \"$WIN_TEST_TMPDIR\" --write-metadata \"$URL_NOSET\""
			gallery-dl "${URL_GALLERY_DL_PARAMS[@]}" -f '{num}.{extension}' -D "$WIN_TEST_TMPDIR" --write-metadata "$URL_NOSET" 2>&1 >/dev/null
			if [ $? -eq 0 ] && [ "$(ls -A "$TEST_TMPDIR" 2>/dev/null)" ]; then
				PROCESSED_URL="$URL_NOSET"
				echo "Download succeeded, removed set param, new URL: $PROCESSED_URL"
				# Keep the test temp directory for later use (will be added to cleanup when used as IMAGES_TMPDIR)
				PRE_DOWNLOADED_DIR="$TEST_TMPDIR"
			else
				# Track temp directory for cleanup if download failed
				add_to_cleanup "$TEST_TMPDIR"
				echo "Download failed, trying to infer position"
			fi
		fi
		# set was not removed, so try to infer position
		if [[ "$PROCESSED_URL" =~ [?\&](set=a\.[0-9]+|set=gm\.[0-9]+) ]]; then
			# Extract fbid from URL if present
			if [[ "$PROCESSED_URL" =~ [?\&]fbid=([0-9]+) ]]; then
				local FBID="${BASH_REMATCH[1]}"
				echo "Found fbid: $FBID"
				
				# Download images and monitor output line-by-line to find position of image with fbid
				echo "Finding position of image with fbid $FBID by monitoring gallery-dl output in real-time..."
				local FOUND=0
				local FOUND_POSITION=0
				
				local POSITION_TMPDIR=$(mktemp -d /tmp/gallery_dl_position_XXXXXXXX)
				local WIN_POSITION_TMPDIR=$(cygpath -w "$POSITION_TMPDIR")
				# Add temp directory to cleanup list
				add_to_cleanup "$POSITION_TMPDIR"
				
				
				# Start gallery-dl and read its output line by line
				echo "Starting gallery-dl and reading output line-by-line..."
				
				# Use local variables (no files needed since we use process substitution, not pipe)
				local current_count=0
				
				# Run gallery-dl and read its output line by line using process substitution
				# Process substitution doesn't create a subshell, so variables are accessible
				# When we break out of the loop, gallery-dl will receive SIGPIPE on its next write
				while IFS= read -r line; do
					# Parse the line to extract filename
					# gallery-dl may output full paths or just filenames
					local filename=""
					
					# Try to extract filename from the line - look for number.extension pattern
					# Match patterns like: "1.jpg", "2.png", or full paths containing them
					if [[ "$line" =~ ([0-9]+\.[a-zA-Z]+) ]]; then
						filename="${BASH_REMATCH[1]}"
						
						# Check if we've reached max file search limit
						if [ "$current_count" -ge "$MAX_FILE_SEARCH" ]; then
							echo "Reached maximum file search limit ($MAX_FILE_SEARCH), stopping"
							break
						fi
						
						# If filename extracted, check the corresponding file
						if [ -n "$filename" ] && [ $FOUND -eq 0 ]; then
							local file="$POSITION_TMPDIR/$filename"
							
							# Wait briefly for file to appear if it's mentioned in output
							wait_for_file "$file" 20
							
							# Skip if file still doesn't exist
							if [ ! -f "$file" ]; then
								continue
							fi
							
							# Extract position number from filename
							local position=${filename%%.*}
							if ! [[ "$position" =~ ^[0-9]+$ ]]; then
								continue
							fi
							
							# Wait for metadata file to appear and get its path
							local meta=$(wait_for_metadata_file "$file" 10)
							
							# Increment file count
							((current_count++))
							
							# Extract ID from JSON metadata for display (only 'id' field)
							local found_id=""
							if [ -f "$meta" ]; then
								found_id=$(extract_meta_id "$meta")
								if [ $? -ne 0 ]; then
									found_id=""
								fi
							fi
							
							# Print single line: file processed and its ID
							if [ -n "$found_id" ]; then
								echo "Processed file: $filename (ID: $found_id)"
							else
								echo "Processed file: $filename (ID: not found)"
							fi
							
							# Check if the 'id' field in metadata matches the FBID we're looking for (only check 'id' field)
							if [ -f "$meta" ]; then
								local meta_id=$(extract_meta_id_only "$meta")
								if [ $? -eq 0 ] && [ "$meta_id" = "$FBID" ]; then
									FOUND_POSITION=$position
									FOUND=1
									echo "Found matching image at position $position"
									break
								fi
							fi
						fi
					fi
					
					# Break if found or max count reached
					if [ $FOUND -eq 1 ]; then
						break
					fi
					if [ "$current_count" -ge "$MAX_FILE_SEARCH" ]; then
						break
					fi
				done < <(gallery-dl "${URL_GALLERY_DL_PARAMS[@]}" -f '{num}.{extension}' -D "$WIN_POSITION_TMPDIR" --write-metadata "$PROCESSED_URL" 2>&1)
				
				# Final check if we haven't found it yet
				if [ $FOUND -eq 0 ] && [ -d "$POSITION_TMPDIR" ]; then
					echo "Doing final check of all downloaded files..."
					local files=($(get_sorted_files "$POSITION_TMPDIR"))
					for fname in "${files[@]}"; do
						local file="$POSITION_TMPDIR/$fname"
						local result=$(check_file_for_fbid "$file" "$FBID")
						if [ $? -eq 0 ] && [ -n "$result" ]; then
							FOUND_POSITION=$result
							FOUND=1
							echo "Found matching image at position $FOUND_POSITION"
							break
						fi
					done
				fi
				
				if [ $FOUND -eq 1 ] && [ $FOUND_POSITION -gt 0 ]; then
					# We already downloaded the file, reuse it instead of redownloading
					# Create a directory with just the matching file
					local MATCHING_FILE_DIR=$(mktemp -d /tmp/gallery_dl_matching_XXXXXXXX)
					local WIN_MATCHING_FILE_DIR=$(cygpath -w "$MATCHING_FILE_DIR")
					# Return directory for caller to add to cleanup list
					download_images_ret_temp_dir="$MATCHING_FILE_DIR"
					
					# Find the file at the matching position
					local matching_filename=""
					local files=($(get_sorted_files "$POSITION_TMPDIR"))
					for fname in "${files[@]}"; do
						local file="$POSITION_TMPDIR/$fname"
						[[ "$file" == *.json ]] && continue
						
						local basename=$(basename "$file")
						local position=${basename%%.*}
						if [[ "$position" =~ ^[0-9]+$ ]] && [ "$position" -eq "$FOUND_POSITION" ]; then
							matching_filename="$fname"
							# Copy the image file and its metadata
							cp "$file" "$MATCHING_FILE_DIR/" 2>/dev/null
							# Copy metadata file if it exists
							local meta="${file}.json"
							if [ -f "$meta" ]; then
								cp "$meta" "$MATCHING_FILE_DIR/" 2>/dev/null
							fi
							break
						fi
					done
					
					if [ -n "$matching_filename" ] && [ "$(ls -A "$MATCHING_FILE_DIR" 2>/dev/null)" ]; then
						# Use the pre-downloaded directory instead of setting range
						PRE_DOWNLOADED_DIR="$MATCHING_FILE_DIR"
						echo "Reusing already downloaded file at position $FOUND_POSITION"
					else
						# Fallback: use range if we couldn't find/copy the file
						URL_GALLERY_DL_PARAMS+=("--range" "$FOUND_POSITION")
					fi
				else
					download_images_ret_error="Could not find image with fbid $FBID after searching $MAX_FILE_SEARCH files"
					download_images_ret_success=1
					return
				fi
			else
				# No FBID in URL, don't set range
				:
			fi
		fi
		echo "Modified URL: $PROCESSED_URL"
	fi
	
	# If we already have a pre-downloaded directory from Facebook URL processing, use it
	if [ -n "$PRE_DOWNLOADED_DIR" ] && [ -d "$PRE_DOWNLOADED_DIR" ] && [ "$(ls -A "$PRE_DOWNLOADED_DIR" 2>/dev/null)" ]; then
		echo "Using pre-downloaded images from $PRE_DOWNLOADED_DIR"
		local IMAGES_TMPDIR="$PRE_DOWNLOADED_DIR"
		# Add the pre-downloaded directory to cleanup list (it's a temp directory)
		add_to_cleanup "$PRE_DOWNLOADED_DIR"
		DOWNLOADED=1
	else
		echo "Attempting to download as images using gallery-dl"
		local IMAGES_TMPDIR=$(mktemp -d /tmp/gallery_dl_XXXXXXXX)
		local WIN_IMAGES_TMPDIR=$(cygpath -w "$IMAGES_TMPDIR")
		# Add temp directory to cleanup list
		add_to_cleanup "$IMAGES_TMPDIR"
		
		gallery-dl "${URL_GALLERY_DL_PARAMS[@]}" -f '{num}.{extension}' -D "$WIN_IMAGES_TMPDIR" --write-metadata "$PROCESSED_URL" 2>/dev/null
		
		if [ $? -eq 0 ] && [ "$(ls -A "$IMAGES_TMPDIR" 2>/dev/null)" ]; then
			DOWNLOADED=1
		fi
	fi
	
	if [ $DOWNLOADED -eq 1 ] && [ "$(ls -A "$IMAGES_TMPDIR" 2>/dev/null)" ]; then
		# Process downloaded images
		local files=($(get_sorted_files "$IMAGES_TMPDIR"))
		for fname in "${files[@]}"; do
			local file="$IMAGES_TMPDIR/$fname"
			# Skip metadata files
			[[ "$file" == *.json ]] && continue
			download_images_ret_files+=("$file")
			# Add the downloaded file to cleanup list when it's added to return array
			add_to_cleanup "$file"
			echo "Downloaded image: $file"
			
			# Extract caption from metadata if available
			local extracted_caption=""
			local meta="${file}.json"
			if [ -f "$meta" ] && [ "$APPEND_ORIGINAL_COMMENT" -eq 1 ]; then
				extracted_caption=$(jq -r '.caption // empty' "$meta" 2>/dev/null | sed 's/^"\|"$//g')
			fi
			local file_caption=$(build_caption "$DESCRIPTION_CANDIDATE" "$extracted_caption" "$APPEND_ORIGINAL_COMMENT")
			download_images_ret_captions+=("$file_caption")
		done
		
		if [ -z "$SOURCE_CANDIDATE" ]; then
			download_images_ret_source="$PROCESSED_URL"
		fi
		download_images_ret_success=0
	fi
}

# Function to upload a file to a blossom server
# Parameters:
#   $1: FILE - path to file to upload
#   $2: BLOSSOM - blossom server URL
#   $3: KEY - private key for upload
# Returns: uploaded file URL via stdout
# Exit code: 0 on success, 1 on failure
upload_file_to_blossom() {
	local FILE="$1"
	local BLOSSOM="$2"
	local KEY="$3"
	
	local FILE_WIN=$(cygpath -w "$FILE")
	if [ ! -f "$FILE" ]; then
		echo "File does not exist: $FILE" >&2
		return 1
	fi
	
	echo "Uploading $FILE to $BLOSSOM" >&2
	local upload_output=$(nak blossom upload --server "$BLOSSOM" "$FILE_WIN" "--sec" "$KEY")
	local RESULT=$?
	if [ $RESULT -ne 0 ]; then
		echo "Failed to upload file $FILE to $BLOSSOM with nak, trying with blossom-cli" >&2
		upload_output=$(blossom-cli upload -file "$FILE_WIN" -server "$BLOSSOM" -privkey "$KEY" 2>/dev/null)
		RESULT=$?
	fi
	if [ $RESULT -ne 0 ]; then
		echo "Failed to upload file $FILE to $BLOSSOM: $upload_output" >&2
		return 1
	fi
	
	local file_url=$(echo "$upload_output" | jq -r '.url')
	if [ -z "$file_url" ] || [ "$file_url" == "null" ]; then
		echo "Failed to extract URL from upload output: $upload_output" >&2
		return 1
	fi
	
	echo "Uploaded to: $file_url" >&2
	echo "$file_url"
	return 0
}

# Function to decrypt key from various formats
# Parameters:
#   $1: NSEC_KEY_VAL - NSEC key value (may be empty)
#   $2: NCRYPT_KEY_VAL - NCRYPT key value (may be empty)
#   $3: KEY_VAL - default key value (may be empty)
#   $4: PASSWORD - password for decryption (may be empty, will prompt if needed)
# Returns: decrypted key via stdout
# Exit code: 0 on success, 1 on failure
decrypt_key() {
	local NSEC_KEY_VAL="$1"
	local NCRYPT_KEY_VAL="$2"
	local KEY_VAL="$3"
	local PASSWORD="$4"
	
	local decrypted_key=""
	
	if [ -n "$NSEC_KEY_VAL" ]; then
		echo "Using NSEC_KEY to decrypt the secret key" >&2
		local DECODED=$(nak decode $NSEC_KEY_VAL)
		if [ $? -ne 0 ]; then
			echo "Failed to decrypt the key" >&2
			return 1
		fi
		
		# Check if the decoded output is JSON (starts with {) or a hex key
		if echo "$DECODED" | grep -q '^{'; then
			# It's JSON, extract the private_key field
			decrypted_key=$(echo "$DECODED" | jq -r .private_key)
		else
			# It's already a hex key, use it directly
			decrypted_key="$DECODED"
		fi
	elif [ -n "$NCRYPT_KEY_VAL" ]; then
		echo "Using NCRYPT_KEY to decrypt the secret key" >&2
		if [ -z "$PASSWORD" ]; then
			read -sp "Enter password to decrypt the secret key: " PASSWORD
			echo
		fi
		decrypted_key=$(nak key decrypt "$NCRYPT_KEY_VAL" "$PASSWORD")
		if [ $? -ne 0 ]; then
			echo "Failed to decrypt the key" >&2
			return 1
		fi
	else
		echo "Using default key" >&2
		if [ -z "$KEY_VAL" ]; then
			echo "Key is empty, cannot decrypt" >&2
			return 1
		fi
		if [ -z "$PASSWORD" ]; then
			read -sp "Enter password to decrypt the secret key: " PASSWORD
			echo
		fi
		decrypted_key=$(echo "$KEY_VAL" | openssl enc -aes-256-cbc -pbkdf2 -d -a -pass pass:"$PASSWORD")
		if [ $? -ne 0 ]; then
			echo "Failed to decrypt the key" >&2
			return 1
		fi
	fi
	
	if [ -z "$decrypted_key" ]; then
		echo "Decryption failed, key is empty" >&2
		return 1
	fi
	
	echo "$decrypted_key"
	return 0
}

# Function to normalize a media URL (removes tracking params, normalizes)
# Parameters:
#   $1: MEDIA_FILE - URL or file path to normalize
# Returns: normalized URL via stdout (empty if not a URL)
normalize_media_url() {
	local MEDIA_FILE="$1"
	
	if [[ "$MEDIA_FILE" =~ ^https?:// ]]; then
		# It's a URL
		local TMP_FILE=$(echo "$MEDIA_FILE" | tr -d '\r\n')
		# remove url params from the file but only if from instagram
		if [[ "$TMP_FILE" =~ ^https?://.*instagram\.com/.* ]]; then
			TMP_FILE=$(echo "$TMP_FILE" | sed 's/\?.*//')
		fi
		echo "$TMP_FILE"
	else
		# It's a local file, return empty
		echo ""
	fi
}

# Function to get filename from URL or file path
# Parameters:
#   $1: MEDIA_FILE - URL or file path
# Returns: filename via stdout
get_media_filename() {
	local MEDIA_FILE="$1"
	
	if [[ "$MEDIA_FILE" =~ ^https?:// ]]; then
		# It's a URL - normalize first to get clean URL
		local normalized=$(normalize_media_url "$MEDIA_FILE")
		# remove trailing "/" from URL if it exists
		local TMP_FILE=$(echo "$normalized" | sed 's:/*$::')
		local FILE_NAME=$(basename "$TMP_FILE")
		echo "$FILE_NAME"
	else
		# It's a local file
		local FILE_NAME=$(basename "$MEDIA_FILE")
		echo "$FILE_NAME"
	fi
}

# Function to check if media file is in history and return normalized URL or filename
# Parameters:
#   $1: MEDIA_FILE - URL or file path to check
#   $2: HISTORY_FILE - path to history file
#   $3: DISABLE_HASH_CHECK - 1 to disable, 0 otherwise
# Returns: filename via stdout if in history, normalized URL via stdout if not (empty if local file)
# Exit code: 0 if NOT in history (ok to proceed), 1 if in history (should exit)
check_media_history() {
	local MEDIA_FILE="$1"
	local HISTORY_FILE="$2"
	local DISABLE_HASH_CHECK="$3"
	
	local FILE_NAME=$(get_media_filename "$MEDIA_FILE")
	if check_history "$FILE_NAME" "$HISTORY_FILE" "$DISABLE_HASH_CHECK"; then
		# Found in history - return filename
		echo "$FILE_NAME"
		return 1  # Found in history - should exit
	fi
	
	# Not in history - return normalized URL (empty if local file)
	local normalized_url=$(normalize_media_url "$MEDIA_FILE")
	echo "$normalized_url"
	return 0  # Not found - ok to proceed
}

# Function to clean up source URL by removing problematic parameters
# Parameters:
#   $1: SOURCE_URL - URL to clean up
# Returns cleaned URL via stdout
cleanup_source_url() {
	local SOURCE_URL="$1"
	
	# remove param idorvanity= first, since it breaks gallery-dl
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
	
	echo "$SOURCE_URL"
}

# Function to display usage information
usage() {
	local SCRIPT_NAME=$(basename "$0")
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

# Initialize cleanup files array (already initialized as empty array above)

# default values, override if exists in ~/.nostr/${SCRIPT_NAME%.*}
DISPLAY_SOURCE="${DISPLAY_SOURCE:-0}"
POW_DIFF="${POW_DIFF:-20}"
APPEND_ORIGINAL_COMMENT="${APPEND_ORIGINAL_COMMENT:-1}"
USE_COOKIES_FF="${USE_COOKIES_FF:-0}"

# Load environment variables from ~/.nostr/girino if it exists
if [[ -f "$HOME/.nostr/${SCRIPT_NAME%.*}" ]]; then
    # shellcheck source=/dev/null
    source "$HOME/.nostr/${SCRIPT_NAME%.*}"
else
	die "No environment variables found in ~/.nostr/${SCRIPT_NAME%.*}"
fi

# Ensure that at least one key variable is set, otherwise exit with error
if [[ -z "$NSEC_KEY" && -z "$KEY" && -z "$NCRYPT_KEY" ]]; then
	die "Error: No key variable is set. Please set NSEC_KEY, KEY, or NCRYPT_KEY in ~/.nostr/${SCRIPT_NAME%.*}"
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

# parse command line params
ALL_MEDIA_FILES=()
CONVERT_VIDEO="${CONVERT_VIDEO:-1}"
SEND_TO_RELAY="${SEND_TO_RELAY:-1}"
DISABLE_HASH_CHECK="${DISABLE_HASH_CHECK:-0}"
MAX_FILE_SEARCH="${MAX_FILE_SEARCH:-10}"

while (( "$#" )); do
	PARAM="$1"
	PARAM=$(echo "$PARAM" | tr -d '\r\n\t' | sed 's/[[:space:]]\+$//')
	if [ -f "$PARAM" ]; then
		MIME_TYPE=$(file --mime-type -b "$PARAM")
		if [[ "$MIME_TYPE" == image/* || "$MIME_TYPE" == video/* ]]; then
			ALL_MEDIA_FILES+=("$PARAM")
		else
			echo "Unsupported file type: $PARAM => $MIME_TYPE"
			exit 1
		fi
	elif [[ "$PARAM" =~ ^https?:// ]]; then
		# Check if this contains multiple URLs (space-separated)
		if [[ "$PARAM" =~ https?://.*[[:space:]]+https?:// ]]; then
			# Contains multiple URLs, split and add each one
			while read -r url; do
				if [[ "$url" =~ ^https?:// ]]; then
					# Remove ?utm_source=ig_web_copy_link if present at the end of the URL
					url=$(clean_url "$url")
					ALL_MEDIA_FILES+=("$url")
				fi
			done <<< "$(echo "$PARAM" | grep -oE 'https?://[^[:space:]]+' || echo "$PARAM")"
		else
			# Single URL
		# Remove ?utm_source=ig_web_copy_link if present at the end of the URL
		PARAM=$(clean_url "$PARAM")
			ALL_MEDIA_FILES+=("$PARAM")
		fi
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
	elif [[ "$PARAM" == "--max-file-search" || "$PARAM" == "-max-file-search" ]]; then
		MAX_FILE_SEARCH="$2"
		if [ -z "$MAX_FILE_SEARCH" ] || ! [[ "$MAX_FILE_SEARCH" =~ ^[0-9]+$ ]]; then
			echo "Invalid value for --max-file-search: $MAX_FILE_SEARCH (must be a number)"
			exit 1
		fi
		shift  # shift to remove the value from the params
	else
		# stop processing params if it's not a file or url
		# do not shift to keep the description and source

		break
	fi
	# param was used, shift
	shift
done

# Check if at least one media file is provided
if [ ${#ALL_MEDIA_FILES[@]} -eq 0 ]; then
	echo "No image or video file provided"
	exit 1
fi

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

# Check if the file names are present in the history file
ORIGINAL_URLS=()
for MEDIA_FILE in "${ALL_MEDIA_FILES[@]}"; do
	result=$(check_media_history "$MEDIA_FILE" "$HISTORY_FILE" "$DISABLE_HASH_CHECK")
	if [ $? -ne 0 ]; then
		# File is in history - result contains filename
		echo "File name already processed: $result"
		exit 1
	fi
	
	# Not in history - result contains normalized URL (empty if local file)
	# Add normalized URL if it's not empty (it's a URL, not a local file)
	if [ -n "$result" ]; then
		ORIGINAL_URLS+=("$result")
	fi
done

# Decrypt key from various formats
KEY=$(decrypt_key "$NSEC_KEY" "$NCRYPT_KEY" "$KEY" "$PASSWORD")
if [ $? -ne 0 ]; then
	die "Decryption failed, key is empty"
fi

# Prepare gallery-dl params
GALLERY_DL_PARAMS=()
		if [ "$USE_COOKIES_FF" -eq 1 ]; then
	GALLERY_DL_PARAMS+=(--cookies-from-browser firefox)
fi
GALLERY_DL_PARAMS+=(--user-agent "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:120.0) Gecko/20100101 Firefox/120.0")

# Process all media files - download URLs if needed, keep local files
PROCESSED_FILES=()
FILE_CAPTIONS=()
FILE_SOURCES=()
FILE_GALLERIES=()  # Track which gallery/media item each file belongs to
GALLERY_ID=0
	for MEDIA_ITEM in "${ALL_MEDIA_FILES[@]}"; do
	if [[ "$MEDIA_ITEM" =~ ^https?:// ]]; then
		# It's a URL - try to download as video first, then as image
		echo "Processing URL: $MEDIA_ITEM"
		
		# Prepare gallery-dl params as string for passing to function
		GALLERY_DL_PARAMS_STR=$(serialize_array "${GALLERY_DL_PARAMS[@]}")
		
		# Try video download first for any URL
		# Initialize return variables
		download_video_ret_files=()
		download_video_ret_captions=()
		download_video_ret_source=""
		download_video_ret_success=1
		
		download_video "$MEDIA_ITEM" "$HISTORY_FILE" "$CONVERT_VIDEO" "$USE_COOKIES_FF" "$APPEND_ORIGINAL_COMMENT" "$DISABLE_HASH_CHECK" "$DESCRIPTION_CANDIDATE" "$SOURCE_CANDIDATE"
		VIDEO_DOWNLOAD_RESULT="${download_video_ret_success:-1}"
		
		# If video download succeeded, use its return values
		if [ "$VIDEO_DOWNLOAD_RESULT" -eq 0 ]; then
			# Append downloaded files and captions to parallel arrays
			if [ ${#download_video_ret_files[@]} -gt 0 ]; then
				idx=0
				for file in "${download_video_ret_files[@]}"; do
					PROCESSED_FILES+=("$file")
					if [ $idx -lt ${#download_video_ret_captions[@]} ]; then
						FILE_CAPTIONS+=("${download_video_ret_captions[$idx]}")
					else
						FILE_CAPTIONS+=("")
					fi
					FILE_GALLERIES+=("$GALLERY_ID")
					((idx++))
				done
			fi
			# Update source if provided
			if [ -n "$download_video_ret_source" ]; then
				cleaned_source=$(cleanup_source_url "$download_video_ret_source")
				FILE_SOURCES+=("$cleaned_source")
			fi
			((GALLERY_ID++))
		else
			# If video download failed, try image download with gallery-dl
			echo "Video download failed, trying gallery-dl for images"
			# Initialize return variables
			download_images_ret_files=()
			download_images_ret_captions=()
			download_images_ret_source=""
			download_images_ret_success=1
			download_images_ret_temp_dir=""
			
			# Call download_images function (Facebook URL handling is done inside)
			download_images "$MEDIA_ITEM" "$GALLERY_DL_PARAMS_STR" "$APPEND_ORIGINAL_COMMENT" "$DESCRIPTION_CANDIDATE" "$SOURCE_CANDIDATE" "$MAX_FILE_SEARCH"
			IMAGE_DOWNLOAD_RESULT="${download_images_ret_success:-1}"
			
			# Add temp directory to cleanup list if returned
			if [ -n "$download_images_ret_temp_dir" ]; then
				add_to_cleanup "$download_images_ret_temp_dir"
			fi
			
			if [ "$IMAGE_DOWNLOAD_RESULT" -eq 0 ]; then
				# For gallery images, all files from same gallery share the same gallery ID and caption
				# Use the first caption (they should all be the same or similar for gallery downloads)
				CAPTIONS_STR=$(serialize_array "${download_images_ret_captions[@]}")
				gallery_caption=$(get_first_non_empty_caption "$CAPTIONS_STR")
				
				# Append downloaded files to parallel arrays - all from same gallery
				if [ ${#download_images_ret_files[@]} -gt 0 ]; then
					current_gallery_id=$GALLERY_ID
					for file in "${download_images_ret_files[@]}"; do
						PROCESSED_FILES+=("$file")
						# For gallery images, store caption once per gallery (will be used after all URLs)
						FILE_CAPTIONS+=("")
						FILE_GALLERIES+=("$current_gallery_id")
					done
					# Store gallery caption in the last file's position (we'll handle it differently during content building)
					if [ ${#PROCESSED_FILES[@]} -gt 0 ] && [ -n "$gallery_caption" ]; then
						last_idx=$((${#PROCESSED_FILES[@]} - 1))
						FILE_CAPTIONS[$last_idx]="$gallery_caption"
					fi
				fi
				# Update source if provided
				if [ -n "$download_images_ret_source" ]; then
					cleaned_source=$(cleanup_source_url "$download_images_ret_source")
					FILE_SOURCES+=("$cleaned_source")
				fi
				((GALLERY_ID++))
			else
				if [ -n "$download_images_ret_error" ]; then
					die "$download_images_ret_error"
				else
					die "Failed to download from URL: $MEDIA_ITEM"
				fi
			fi
		fi
	else
		# It's a local file
		if [ ! -f "$MEDIA_ITEM" ]; then
			die "File does not exist: $MEDIA_ITEM"
		fi
		PROCESSED_FILES+=("$MEDIA_ITEM")
		FILE_CAPTIONS+=("")
		FILE_GALLERIES+=("$GALLERY_ID")
		((GALLERY_ID++))
		echo "Using local file: $MEDIA_ITEM"
	fi
done


# Create an array to store file hashes
FILE_HASHES=()
if [ $DISABLE_HASH_CHECK -eq 0 ]; then
	# Process all processed files
	for FILE in "${PROCESSED_FILES[@]}"; do
		if [ -f "$FILE" ]; then
			# Calculate file hash
			FILE_HASH=$(sha256sum "$FILE" | awk '{print $1}')
			# Check if file hash exists in history file
			if check_history "$FILE_HASH" "$HISTORY_FILE" "$DISABLE_HASH_CHECK"; then
				die "File hash already processed: $FILE"
			fi
			# Add file hash to the array
			FILE_HASHES+=("$FILE_HASH")
		fi
	done
fi

if [ ${#PROCESSED_FILES[@]} -eq 0 ]; then
	die "No files to upload"
fi

# Upload all files via blossom and collect URLs
UPLOAD_URLS=()
RESULT=0
upload_success=0

for TRIES in "${!BLOSSOMS[@]}"; do
	BLOSSOM="${BLOSSOMS[$TRIES]}"
	echo "Using blossom: $BLOSSOM, try: $((TRIES+1))"
	
	UPLOAD_URLS=()
	upload_success=1
	
	for FILE in "${PROCESSED_FILES[@]}"; do
		upload_url=$(upload_file_to_blossom "$FILE" "$BLOSSOM" "$KEY")
		if [ $? -ne 0 ]; then
			upload_success=0
			break
		fi
		UPLOAD_URLS+=("$upload_url")
	done

	if [ $upload_success -eq 0 ]; then
		RESULT=1
		continue
	fi

	# Build content for kind 1 event: interleaved URL -> caption -> URL -> caption, then sources at bottom
	# For gallery images: all URLs first, then caption for the gallery
	# Formatting: empty line after images before caption, 2 empty lines after caption before next URL
	UPLOAD_URLS_STR=$(serialize_array "${UPLOAD_URLS[@]}")
	FILE_CAPTIONS_STR=$(serialize_array "${FILE_CAPTIONS[@]}")
	FILE_GALLERIES_STR=$(serialize_array "${FILE_GALLERIES[@]}")
	FILE_SOURCES_STR=$(serialize_array "${FILE_SOURCES[@]}")
	CONTENT=$(build_event_content "$UPLOAD_URLS_STR" "$FILE_CAPTIONS_STR" "$FILE_GALLERIES_STR" "$FILE_SOURCES_STR" "$DISPLAY_SOURCE")

	# Print content for debugging before creating event
	echo "=== Event Content (Debug) ==="
	echo "$CONTENT"
	echo "=== End Event Content ==="

	# Create kind 1 event with nak
	echo "Creating kind 1 event with content length: ${#CONTENT}"
	
	NAK_CMD=("nak" "event" "--kind" "1" "-sec" "$KEY" "--pow" "$POW_DIFF")
	if [ "$SEND_TO_RELAY" -eq 1 ]; then
		NAK_CMD+=("--auth" "-sec" "$KEY")
		for RELAY in $RELAYS; do
			NAK_CMD+=("$RELAY")
		done
	fi
	
	if [ -n "$CONTENT" ]; then
		NAK_CMD+=("--content" "$(echo -e "$CONTENT")")
	else
		NAK_CMD+=("--content" "")
	fi
	
	echo "${NAK_CMD[@]}"
	"${NAK_CMD[@]}"
	RESULT=$?
	
	if [ $RESULT -eq 0 ]; then
		echo "Successfully published kind 1 event"
		break
	else
		echo "Failed to publish kind 1 event, trying next blossom server"
		RESULT=1
	fi
done

if [ $RESULT -ne 0 ]; then
	die "Failed to upload files and publish event"
fi

# Add the file hash to history file only if the upload was successful
# but only if sent to relays
if [ "$SEND_TO_RELAY" -eq 1 ] && [ "$DISABLE_HASH_CHECK" -eq 0 ] && [ $RESULT -eq 0 ]; then
	# Collect local files from ALL_MEDIA_FILES
	LOCAL_FILES=()
	for MEDIA_FILE in "${ALL_MEDIA_FILES[@]}"; do
		if [ -f "$MEDIA_FILE" ]; then
			# It's a local file
			LOCAL_FILES+=("$MEDIA_FILE")
		fi
	done
	
	# Write hashes, URLs, and local files to history
	FILE_HASHES_STR=$(serialize_array "${FILE_HASHES[@]}")
	write_to_history "$HISTORY_FILE" "$FILE_HASHES_STR"
	
	ORIGINAL_URLS_STR=$(serialize_array "${ORIGINAL_URLS[@]}")
	write_to_history "$HISTORY_FILE" "$ORIGINAL_URLS_STR"
	
	if [ ${#LOCAL_FILES[@]} -gt 0 ]; then
		LOCAL_FILES_STR=$(serialize_array "${LOCAL_FILES[@]}")
		write_to_history "$HISTORY_FILE" "$LOCAL_FILES_STR"
	fi
fi

# Remove the tempfile
cleanup
