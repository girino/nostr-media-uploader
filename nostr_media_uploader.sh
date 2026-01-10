#!/bin/bash

# Script-level constants (read-only after definition)
SCRIPT_DIR=$(dirname "$0")
readonly SCRIPT_DIR

BLOSSOMS=(
	"https://blossom.band/"
	"https://nostr.download"
	"https://blossom.primal.net"
)
# Shuffle the BLOSSOMS array (disabled temporarily until finished)
#BLOSSOMS=($(shuf -e "${BLOSSOMS[@]}"))
readonly BLOSSOMS

RELAYS="wss://bcast.girino.org wss://nip13.girino.org wss://nostr.girino.org wss://wot.girino.org"
readonly RELAYS

# Global array to track files/directories for cleanup (used only by add_to_cleanup and cleanup functions)
CLEANUP_FILES=()

# Function to detect operating system type
# Sets global variable OS_TYPE ("cygwin", "linux", or "unknown")
# Currently supports Cygwin and Linux detection
# Returns: 0 (always succeeds)
detect_os() {
	# Check if OSTYPE contains "cygwin" or if cygpath command exists
	if [[ "${OSTYPE:-}" == *"cygwin"* ]] || command -v cygpath >/dev/null 2>&1; then
		OS_TYPE="cygwin"
	# Check if OSTYPE indicates Linux
	elif [[ "${OSTYPE:-}" == *"linux"* ]] || [[ "$(uname -s 2>/dev/null)" == "Linux" ]]; then
		OS_TYPE="linux"
	else
		# Unknown OS - cannot determine
		OS_TYPE="unknown"
	fi
	return 0
}

# Detect OS and set global variable
OS_TYPE="unknown"
detect_os
if [ "$OS_TYPE" = "unknown" ]; then
	die "Unsupported operating system. This script requires Cygwin or Linux."
fi
readonly OS_TYPE

# Function to check if required commands are installed and provide install instructions
# Returns: 0 if all commands exist, 1 if any are missing
check_required_commands() {
	local MISSING_COMMANDS=()
	local ALL_GOOD=1
	
	# Define required commands and their install instructions
	declare -A COMMANDS
	if [ "$OS_TYPE" = "cygwin" ]; then
		COMMANDS[gallery-dl]="Install gallery-dl (requires >= 1.30.6): pip install gallery-dl==1.30.6"
		COMMANDS[yt-dlp]="Install yt-dlp: pip install yt-dlp"
	elif [ "$OS_TYPE" = "linux" ]; then
		COMMANDS[gallery-dl]="Install gallery-dl (requires >= 1.30.6): pipx install gallery-dl==1.30.6 OR pip install --user gallery-dl==1.30.6 (DO NOT use apt - package is too old)"
		COMMANDS[yt-dlp]="Install yt-dlp: pipx install yt-dlp OR pip install --user yt-dlp (DO NOT use apt - package is too old)"
	fi
	COMMANDS[ffmpeg]="Install ffmpeg: On Cygwin: apt-cyg install ffmpeg; On Linux: apt-get install ffmpeg or yum install ffmpeg"
	COMMANDS[ffprobe]="Install ffprobe: Usually comes with ffmpeg package"
	COMMANDS[jq]="Install jq: On Cygwin: apt-cyg install jq; On Linux: apt-get install jq or yum install jq"
	COMMANDS[nak]="Install nak: See https://github.com/fiatjaf/nak"
	COMMANDS[sha256sum]="Install sha256sum: Usually comes with coreutils package"
	COMMANDS[file]="Install file: On Cygwin: apt-cyg install file; On Linux: apt-get install file or yum install file"
	
	# Check each command
	for cmd in "${!COMMANDS[@]}"; do
		local FOUND=0
		local VERSION_OK=1
		# First check if command exists in PATH
		if command -v "$cmd" >/dev/null 2>&1; then
			FOUND=1
		# Special check for yt-dlp in hardcoded path (Cygwin specific)
		elif [ "$cmd" = "yt-dlp" ] && [ -f "/usr/local/bin/yt-dlp" ]; then
			FOUND=1
		fi
		
		if [ $FOUND -eq 0 ]; then
			MISSING_COMMANDS+=("$cmd")
			ALL_GOOD=0
		fi
	done
	
	# Special version check for gallery-dl (requires >= 1.30.6, latest version that works with Facebook)
	if command -v gallery-dl >/dev/null 2>&1; then
		local VERSION_OUTPUT
		VERSION_OUTPUT=$(gallery-dl --version 2>/dev/null | head -n 1)
		if [ -n "$VERSION_OUTPUT" ]; then
			# Extract version number (e.g., "1.26.9" from "gallery-dl 1.26.9" or just "1.26.9")
			local VERSION
			VERSION=$(echo "$VERSION_OUTPUT" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)
			if [ -n "$VERSION" ]; then
				# Compare version: check if it's >= 1.30.6
				# Split version into major.minor.patch
				local MAJOR MINOR PATCH
				MAJOR=$(echo "$VERSION" | cut -d. -f1)
				MINOR=$(echo "$VERSION" | cut -d. -f2)
				PATCH=$(echo "$VERSION" | cut -d. -f3)
				
				# Check if version is < 1.30.6
				local VERSION_TOO_OLD=0
				if [ "$MAJOR" -lt 1 ]; then
					VERSION_TOO_OLD=1
				elif [ "$MAJOR" -eq 1 ] && [ "$MINOR" -lt 30 ]; then
					VERSION_TOO_OLD=1
				elif [ "$MAJOR" -eq 1 ] && [ "$MINOR" -eq 30 ] && [ "$PATCH" -lt 6 ]; then
					VERSION_TOO_OLD=1
				fi
				
				if [ $VERSION_TOO_OLD -eq 1 ]; then
					echo "Error: gallery-dl version $VERSION found, but version >= 1.30.6 is required (latest that works with Facebook)" >&2
					echo "  Current version: $VERSION" >&2
					echo "  Required version: >= 1.30.6" >&2
					if [ "$OS_TYPE" = "linux" ]; then
						echo "  To upgrade on Linux:" >&2
						echo "    pipx install --force gallery-dl==1.30.6" >&2
						echo "    OR pip install --user --upgrade gallery-dl==1.30.6" >&2
					elif [ "$OS_TYPE" = "cygwin" ]; then
						echo "  To upgrade on Cygwin:" >&2
						echo "    pip install --upgrade gallery-dl==1.30.6" >&2
					fi
					echo "" >&2
					ALL_GOOD=0
				fi
			fi
		fi
	fi
	
	# Check for blossom-cli (optional, used as fallback)
	if ! command -v blossom-cli >/dev/null 2>&1; then
		echo "Warning: blossom-cli not found (optional, used as fallback for uploads)" >&2
	fi
	
	if [ $ALL_GOOD -eq 0 ]; then
		echo "Error: Missing required commands:" >&2
		echo "" >&2
		for cmd in "${MISSING_COMMANDS[@]}"; do
			echo "  - $cmd" >&2
			echo "    ${COMMANDS[$cmd]}" >&2
			echo "" >&2
		done
		
		# Provide OS-specific installation hints
		if [ "$OS_TYPE" = "cygwin" ]; then
			echo "Cygwin installation tips:" >&2
			echo "  - For Python packages (gallery-dl, yt-dlp): Use pip install <package>" >&2
			echo "  - For gallery-dl: pip install gallery-dl==1.30.6 (requires >= 1.30.6)" >&2
			echo "  - For yt-dlp: pip install yt-dlp" >&2
			echo "  - Ensure Python 3 and pip are installed" >&2
		elif [ "$OS_TYPE" = "linux" ]; then
			echo "Linux installation tips:" >&2
			echo "  - DO NOT use apt packages - they are too old" >&2
			echo "  - Use pipx (recommended) or pip install --user" >&2
			echo "" >&2
			if command -v apt-get >/dev/null 2>&1 || command -v apt >/dev/null 2>&1; then
				echo "  Debian/Ubuntu specific:" >&2
				echo "  - Install pipx first: apt install pipx" >&2
				echo "  - For gallery-dl: pipx install gallery-dl==1.30.6" >&2
				echo "    OR pip install --user gallery-dl==1.30.6" >&2
				echo "    (requires >= 1.30.6, latest version that works with Facebook)" >&2
				echo "  - For yt-dlp: pipx install yt-dlp" >&2
				echo "    OR pip install --user yt-dlp" >&2
				echo "  - Note: Modern Linux systems use externally-managed Python environments" >&2
				echo "    Always use --user flag or pipx, avoid 'pip install' without --user" >&2
			elif command -v yum >/dev/null 2>&1; then
				echo "  RHEL/CentOS specific:" >&2
				echo "  - For gallery-dl: pip install --user gallery-dl==1.30.6" >&2
				echo "  - For yt-dlp: pip install --user yt-dlp" >&2
				echo "  - Or use virtualenv" >&2
			elif command -v dnf >/dev/null 2>&1; then
				echo "  Fedora specific:" >&2
				echo "  - Install pipx: dnf install pipx" >&2
				echo "  - For gallery-dl: pipx install gallery-dl==1.30.6" >&2
				echo "    OR pip install --user gallery-dl==1.30.6" >&2
				echo "  - For yt-dlp: pipx install yt-dlp" >&2
				echo "    OR pip install --user yt-dlp" >&2
			fi
		fi
		echo "" >&2
		return 1
	fi
	
	return 0
}

# Check required commands on initialization
if ! check_required_commands; then
	exit 1
fi

# functions 
# Function to convert path for tools that need Windows paths on Cygwin
# On Cygwin, converts Unix path to Windows path using cygpath
# On native Linux, returns path as-is
# Uses global OS_TYPE variable set during initialization
# Parameters:
#   $1: PATH - Unix-style path to convert
# Returns converted path via stdout
convert_path_for_tool() {
	local PATH_TO_CONVERT="$1"
	
	if [ "$OS_TYPE" = "cygwin" ]; then
		# We're on Cygwin, convert path to Windows format
		cygpath -w "$PATH_TO_CONVERT"
	else
		# We're on native Linux (or other Unix-like OS), return path as-is
		echo "$PATH_TO_CONVERT"
	fi
}

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
trap cleanup EXIT INT TERM

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
#   $6: DESCRIPTION - global description to append at the end
# Returns: event content via stdout
# Note: Interleaves URLs and captions, handles galleries, adds sources at bottom
build_event_content() {
	local UPLOAD_URLS_STR="$1"
	local FILE_CAPTIONS_STR="$2"
	local FILE_GALLERIES_STR="$3"
	local FILE_SOURCES_STR="$4"
	local DISPLAY_SOURCE="$5"
	local DESCRIPTION="$6"
	
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
	
	# Add global description at the bottom
	if [ -n "$DESCRIPTION" ]; then
		if [ -n "$CONTENT" ]; then
			# One empty line before description (two newlines = one empty line)
			CONTENT="${CONTENT}"$'\n\n'
		fi
		CONTENT="${CONTENT}${DESCRIPTION}"
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
		
		if [ $source_count -gt 0 ]; then
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

# Function to check if we're running in Docker
# Returns: 0 if in Docker, 1 if not
is_running_in_docker() {
	# Check for .dockerenv file (most reliable Docker indicator)
	if [ -f "/.dockerenv" ]; then
		return 0
	fi
	
	# Check cgroup (alternative method)
	if [ -f "/proc/self/cgroup" ]; then
		if grep -qE 'docker|lxc|kubepods' /proc/self/cgroup 2>/dev/null; then
			return 0
		fi
	fi
	
	return 1
}

# Function to test if a hardware encoder actually works
# This performs an actual encoding test with a synthetic video
# Parameters:
#   $1: ENCODER_NAME - encoder name (e.g., "hevc_qsv", "h264_qsv")
# Returns: 0 if encoder works, 1 if it fails
test_encoder_with_ffmpeg() {
	local ENCODER_NAME="$1"
	
	# Software encoders are always available if compiled in
	if [[ "$ENCODER_NAME" == libx264 ]] || [[ "$ENCODER_NAME" == libx265 ]]; then
		return 0
	fi
	
	# Build encoder-specific test command
	local ENCODER_OPTS=()
	local INPUT_OPTS=()  # Options that must come before -i (like -hwaccel for VAAPI)
	local PIX_FMT=""
	
	case "$ENCODER_NAME" in
		hevc_qsv)
			PIX_FMT="nv12"
			ENCODER_OPTS=(-c:v hevc_qsv -preset slow -pix_fmt "$PIX_FMT" -b:v 1000k)
			;;
		h264_qsv)
			PIX_FMT="nv12"
			ENCODER_OPTS=(-c:v h264_qsv -preset slow -pix_fmt "$PIX_FMT" -b:v 1000k)
			;;
		hevc_vaapi)
			# VAAPI encoder for older Intel processors (fallback when QSV not available)
			# Use software decoding (VAAPI doesn't support all codecs like AV1) and VAAPI encoding
			# Convert to nv12 format and upload to VAAPI surface using filter
			# INPUT_OPTS left empty - use software decoding
			ENCODER_OPTS=(-vf "format=nv12,hwupload" -c:v hevc_vaapi -b:v 1000k)
			;;
		h264_vaapi)
			# VAAPI encoder for older Intel processors (fallback when QSV not available)
			# Use software decoding (VAAPI doesn't support all codecs like AV1) and VAAPI encoding
			# Convert to nv12 format and upload to VAAPI surface using filter
			# INPUT_OPTS left empty - use software decoding
			ENCODER_OPTS=(-vf "format=nv12,hwupload" -c:v h264_vaapi -b:v 1000k)
			;;
		hevc_nvenc)
			ENCODER_OPTS=(-c:v hevc_nvenc -preset slow -rc:v vbr -b:v 1000k)
			;;
		h264_nvenc)
			ENCODER_OPTS=(-c:v h264_nvenc -preset slow -rc:v vbr -b:v 1000k)
			;;
		hevc_amf)
			ENCODER_OPTS=(-c:v hevc_amf -quality speed -b:v 1000k)
			;;
		h264_amf)
			ENCODER_OPTS=(-c:v h264_amf -quality speed -b:v 1000k)
			;;
		h264_v4l2m2m)
			# Raspberry Pi hardware encoder (V4L2 M2M)
			ENCODER_OPTS=(-c:v h264_v4l2m2m -b:v 1000k)
			;;
		hevc_videotoolbox|h264_videotoolbox)
			# VideoToolbox is macOS-only
			return 1
			;;
		*)
			# Unknown encoder
			return 1
			;;
	esac
	
	# Test encoding: generate a 1-second test pattern and try to encode it
	# Use a small resolution (320x240) and low frame rate (1fps) for speed
	# Output to /dev/null since we only care if encoding succeeds
	# INPUT_OPTS must come before -i, ENCODER_OPTS come after -i
	local TEST_OUTPUT
	TEST_OUTPUT=$(ffmpeg -f lavfi "${INPUT_OPTS[@]}" -i "testsrc=duration=1:size=320x240:rate=1" \
		"${ENCODER_OPTS[@]}" \
		-t 1 -f null - 2>&1)
	local TEST_EXIT=$?
	
	if [ $TEST_EXIT -eq 0 ]; then
		return 0
	else
		# Check for common error messages that indicate hardware not available
		if echo "$TEST_OUTPUT" | grep -qiE "no.*device|cannot.*open|failed.*init|not.*available|permission.*denied"; then
			return 1
		fi
		# Other errors might be transient, but for safety, return failure
		return 1
	fi
}

# Function to check if a hardware encoder is actually usable
# This performs pre-flight checks before attempting encoding
# Parameters:
#   $1: ENCODER_NAME - encoder name (e.g., "hevc_qsv", "hevc_nvenc")
# Returns: 0 if encoder is likely usable, 1 if not
check_hardware_encoder_available() {
	local ENCODER_NAME="$1"
	
	# Software encoders are always available if compiled in
	if [[ "$ENCODER_NAME" == libx264 ]] || [[ "$ENCODER_NAME" == libx265 ]]; then
		return 0
	fi
	
	# Test the encoder by actually trying to encode a test pattern
	# This is more reliable than device detection, especially in Docker/WSL2
	if test_encoder_with_ffmpeg "$ENCODER_NAME"; then
		return 0
	else
		return 1
	fi
}

# Function to map encoder name to encoder spec format
# Parameters:
#   $1: ENCODER_NAME - encoder name (e.g., "libx264", "hevc_qsv")
# Returns: encoder spec via stdout in format "encoder_name:type:hw" or empty string if unknown
#   type is "h265" or "h264", hw is "1" (hardware) or "0" (software)
map_encoder_to_spec() {
	local ENCODER_NAME="$1"
	
	case "$ENCODER_NAME" in
		# h265 hardware encoders
		hevc_qsv|hevc_nvenc|hevc_videotoolbox|hevc_amf|hevc_vaapi)
			echo "${ENCODER_NAME}:h265:1"
			;;
		# h264 hardware encoders
		h264_qsv|h264_nvenc|h264_videotoolbox|h264_amf|h264_v4l2m2m|h264_vaapi)
			echo "${ENCODER_NAME}:h264:1"
			;;
		# h265 software encoder
		libx265)
			echo "libx265:h265:0"
			;;
		# h264 software encoder
		libx264)
			echo "libx264:h264:0"
			;;
		*)
			# Unknown encoder
			echo ""
			;;
	esac
}

# Function to get all available encoders in priority order
# Parameters:
#   $1: USER_ENCODERS - optional comma-separated list of encoder names (e.g., "libx264,libx265")
#       If provided, only these encoders will be used (if available in ffmpeg)
#       If empty, uses automatic detection
#   $2: ENABLE_H265 - 1 to enable H265/HEVC encoders, 0 to disable (default: 0, only H264)
# Returns: serialized array of encoder specs via stdout
# Format: "encoder_name:type:hw" where type is "h265" or "h264", hw is "1" or "0"
get_available_encoders_priority() {
	local USER_ENCODERS="$1"
	local ENABLE_H265="${2:-0}"
	
	# Check available encoders - extract encoder names from ffmpeg output
	# Format: "V..... libx264            H.264 / AVC / ..."
	local AVAILABLE_ENCODERS
	AVAILABLE_ENCODERS=$(ffmpeg -encoders 2>/dev/null | grep -E '^[[:space:]]*V' | awk '{print $2}' | tr '\n' ' ')
	
	local ENCODER_LIST=()
	
	# If user specified encoders, use only those
	if [ -n "$USER_ENCODERS" ]; then
		# Split comma-separated list
		IFS=',' read -ra USER_ENCODER_ARRAY <<< "$USER_ENCODERS"
		for ENCODER_NAME in "${USER_ENCODER_ARRAY[@]}"; do
			# Trim whitespace
			ENCODER_NAME=$(echo "$ENCODER_NAME" | xargs)
			
			# Check if encoder exists in ffmpeg
			if echo "$AVAILABLE_ENCODERS" | grep -q "\\b${ENCODER_NAME}\\b"; then
				# Map encoder name to spec format
				local ENCODER_SPEC
				ENCODER_SPEC=$(map_encoder_to_spec "$ENCODER_NAME")
				
				if [ -n "$ENCODER_SPEC" ]; then
					ENCODER_LIST+=("$ENCODER_SPEC")
				else
					echo "Warning: Unknown encoder '$ENCODER_NAME', skipping..." >&2
				fi
			else
				echo "Warning: Encoder '$ENCODER_NAME' not available in ffmpeg, skipping..." >&2
			fi
		done
		
		# If no valid encoders found, return error
		if [ ${#ENCODER_LIST[@]} -eq 0 ]; then
			return 1
		fi
		
		# Serialize and return user-specified encoders
		serialize_array "${ENCODER_LIST[@]}"
		return 0
	fi
	
	# Automatic detection: Priority order: h265 hardware > h264 hardware > h264 software > h265 software
	# (Only if H265 is enabled, otherwise: h264 hardware > h264 software)
	
	# Priority order: h265 hardware > h264 hardware > h264 software > h265 software
	# (For software encoders, libx264 is faster than libx265, so it's preferred)
	# Check each encoder and add to list if available AND hardware is present
	
	# h265 hardware encoders (only if H265 is enabled)
	if [ "$ENABLE_H265" -eq 1 ]; then
		# Check QSV (preferred for Intel processors)
		if echo "$AVAILABLE_ENCODERS" | grep -q '\bhevc_qsv\b'; then
			if check_hardware_encoder_available "hevc_qsv"; then
				ENCODER_LIST+=("hevc_qsv:h265:1")
			fi
		fi
		# Always try VAAPI (fallback for older Intel processors or alternative option)
		if echo "$AVAILABLE_ENCODERS" | grep -q '\bhevc_vaapi\b'; then
			if check_hardware_encoder_available "hevc_vaapi"; then
				ENCODER_LIST+=("hevc_vaapi:h265:1")
			fi
		fi
		if echo "$AVAILABLE_ENCODERS" | grep -q '\bhevc_nvenc\b'; then
			if check_hardware_encoder_available "hevc_nvenc"; then
				ENCODER_LIST+=("hevc_nvenc:h265:1")
			fi
		fi
		if echo "$AVAILABLE_ENCODERS" | grep -q '\bhevc_videotoolbox\b'; then
			if check_hardware_encoder_available "hevc_videotoolbox"; then
				ENCODER_LIST+=("hevc_videotoolbox:h265:1")
			fi
		fi
		if echo "$AVAILABLE_ENCODERS" | grep -q '\bhevc_amf\b'; then
			if check_hardware_encoder_available "hevc_amf"; then
				ENCODER_LIST+=("hevc_amf:h265:1")
			fi
		fi
	fi
	
	# h264 hardware encoders
	# Check QSV (preferred for Intel processors)
	if echo "$AVAILABLE_ENCODERS" | grep -q '\bh264_qsv\b'; then
		if check_hardware_encoder_available "h264_qsv"; then
			ENCODER_LIST+=("h264_qsv:h264:1")
		fi
	fi
	# Always try VAAPI (fallback for older Intel processors or alternative option)
	if echo "$AVAILABLE_ENCODERS" | grep -q '\bh264_vaapi\b'; then
		if check_hardware_encoder_available "h264_vaapi"; then
			ENCODER_LIST+=("h264_vaapi:h264:1")
		fi
	fi
	if echo "$AVAILABLE_ENCODERS" | grep -q '\bh264_nvenc\b'; then
		if check_hardware_encoder_available "h264_nvenc"; then
			ENCODER_LIST+=("h264_nvenc:h264:1")
		fi
	fi
	if echo "$AVAILABLE_ENCODERS" | grep -q '\bh264_videotoolbox\b'; then
		if check_hardware_encoder_available "h264_videotoolbox"; then
			ENCODER_LIST+=("h264_videotoolbox:h264:1")
		fi
	fi
	if echo "$AVAILABLE_ENCODERS" | grep -q '\bh264_amf\b'; then
		if check_hardware_encoder_available "h264_amf"; then
			ENCODER_LIST+=("h264_amf:h264:1")
		fi
	fi
	if echo "$AVAILABLE_ENCODERS" | grep -q '\bh264_v4l2m2m\b'; then
		if check_hardware_encoder_available "h264_v4l2m2m"; then
			ENCODER_LIST+=("h264_v4l2m2m:h264:1")
		fi
	fi
	
	# h264 software encoder (faster than h265, so prefer it)
	if echo "$AVAILABLE_ENCODERS" | grep -q '\blibx264\b'; then
		ENCODER_LIST+=("libx264:h264:0")
	fi
	
	# h265 software encoder (slower but better compression, only if H265 is enabled)
	if [ "$ENABLE_H265" -eq 1 ]; then
		if echo "$AVAILABLE_ENCODERS" | grep -q '\blibx265\b'; then
			ENCODER_LIST+=("libx265:h265:0")
		fi
	fi
	
	# Serialize array and return
	if [ ${#ENCODER_LIST[@]} -eq 0 ]; then
		return 1
	fi
	
	serialize_array "${ENCODER_LIST[@]}"
	return 0
}

# Function to convert video using selected encoder
# Parameters:
#   $1: INPUT_FILE - input video file path (will be converted via convert_path_for_tool)
#   $2: OUTPUT_FILE - output video file path (will be converted via convert_path_for_tool)
#   $3: ENCODER - encoder name (e.g., "hevc_qsv", "libx265", "h264_qsv", "libx264")
#   $4: ENCODER_TYPE - "h265" or "h264"
#   $5: IS_HARDWARE - "1" if hardware accelerated, "0" if software
#   $6: BITRATE - source bitrate (will be adjusted based on encoder type)
# Returns: 0 on success, 1 on failure
convert_video_with_encoder() {
	local INPUT_FILE="$1"
	local OUTPUT_FILE="$2"
	local ENCODER="$3"
	local ENCODER_TYPE="$4"
	local IS_HARDWARE="$5"
	local BITRATE="$6"
	
	local WIN_INPUT=$(convert_path_for_tool "$INPUT_FILE")
	local WIN_OUTPUT=$(convert_path_for_tool "$OUTPUT_FILE")
	
	# Get aspect ratio, resolution, and SAR from input video to preserve them
	# This provides maximum hints to the blossom server for proper re-encoding
	local ASPECT_RATIO
	local INPUT_WIDTH INPUT_HEIGHT
	local SAR="1:1"  # Default to square pixels if not found
	
	# Get display aspect ratio (DAR)
	ASPECT_RATIO=$(ffprobe -v error -select_streams v:0 -show_entries stream=display_aspect_ratio -of default=noprint_wrappers=1:nokey=1 "$WIN_INPUT" 2>/dev/null | tr -d '\r\n' | xargs)
	
	# Get resolution (width and height)
	INPUT_WIDTH=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of default=noprint_wrappers=1:nokey=1 "$WIN_INPUT" 2>/dev/null | tr -d '\r\n' | xargs)
	INPUT_HEIGHT=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of default=noprint_wrappers=1:nokey=1 "$WIN_INPUT" 2>/dev/null | tr -d '\r\n' | xargs)
	
	# Get sample aspect ratio (SAR)
	local SAR_VALUE
	SAR_VALUE=$(ffprobe -v error -select_streams v:0 -show_entries stream=sample_aspect_ratio -of default=noprint_wrappers=1:nokey=1 "$WIN_INPUT" 2>/dev/null | tr -d '\r\n' | xargs)
	
	# Use extracted SAR if available and valid, otherwise default to 1:1 (square pixels)
	# SAR must be in format "num:num" and not be "0:1" or "1:0" or "N/A"
	if [ -n "$SAR_VALUE" ] && [ "$SAR_VALUE" != "N/A" ] && [ "$SAR_VALUE" != "0:1" ] && [ "$SAR_VALUE" != "1:0" ] && [[ "$SAR_VALUE" =~ ^[0-9]+:[0-9]+$ ]]; then
		SAR="$SAR_VALUE"
	fi
	
	# If aspect ratio not found, try calculating from width/height
	if [ -z "$ASPECT_RATIO" ] || [ "$ASPECT_RATIO" = "N/A" ]; then
		if [ -n "$INPUT_WIDTH" ] && [ -n "$INPUT_HEIGHT" ] && [ "$INPUT_WIDTH" != "N/A" ] && [ "$INPUT_HEIGHT" != "N/A" ]; then
			# Calculate aspect ratio (simplified to common ratio)
			local GCD
			GCD=$(awk "BEGIN {
				a=$INPUT_WIDTH; b=$INPUT_HEIGHT;
				while(b) {t=b; b=a%b; a=t}
				print a
			}")
			if [ -n "$GCD" ] && [ "$GCD" -gt 0 ]; then
				local W_RATIO=$((INPUT_WIDTH / GCD))
				local H_RATIO=$((INPUT_HEIGHT / GCD))
				ASPECT_RATIO="${W_RATIO}:${H_RATIO}"
			fi
		fi
	fi
	
	# Calculate bitrate multiplier based on encoder type
	local BITRATE_MULTIPLIER
	if [ "$ENCODER_TYPE" = "h265" ]; then
		# H265 is more efficient, use 1.5x bitrate
		BITRATE_MULTIPLIER=150
	else
		# H264 needs 2x bitrate for similar quality
		BITRATE_MULTIPLIER=200
	fi
	
	local TARGET_BITRATE=$((BITRATE * BITRATE_MULTIPLIER / 100))
	
	# Build encoder-specific options
	local ENCODER_OPTS=()
	local INPUT_OPTS=()  # Options that must come before -i (like -hwaccel for VAAPI)
	local PRESET=""
	local PIX_FMT=""
	local EXTRA_OPTS=()
	
	if [ "$ENCODER" = "hevc_qsv" ]; then
		PRESET="slow"
		PIX_FMT="nv12"
		ENCODER_OPTS=(-c:v hevc_qsv -b:v "${TARGET_BITRATE}" -preset "$PRESET" -pix_fmt "$PIX_FMT")
	elif [ "$ENCODER" = "hevc_vaapi" ]; then
		# VAAPI encoder for older Intel processors (fallback when QSV not available)
		# Use software decoding (VAAPI doesn't support all codecs like AV1) and VAAPI encoding
		# Convert to nv12 format and upload to VAAPI surface using filter
		# INPUT_OPTS left empty - use software decoding
		ENCODER_OPTS=(-vf "format=nv12,hwupload" -c:v hevc_vaapi -b:v "${TARGET_BITRATE}")
	elif [ "$ENCODER" = "hevc_nvenc" ]; then
		PRESET="slow"
		ENCODER_OPTS=(-c:v hevc_nvenc -b:v "${TARGET_BITRATE}" -preset "$PRESET" -rc:v vbr)
	elif [ "$ENCODER" = "hevc_videotoolbox" ]; then
		ENCODER_OPTS=(-c:v hevc_videotoolbox -b:v "${TARGET_BITRATE}")
	elif [ "$ENCODER" = "hevc_amf" ]; then
		PRESET="speed"
		ENCODER_OPTS=(-c:v hevc_amf -b:v "${TARGET_BITRATE}" -quality "$PRESET")
	elif [ "$ENCODER" = "libx265" ]; then
		PRESET="medium"
		ENCODER_OPTS=(-c:v libx265 -b:v "${TARGET_BITRATE}" -preset "$PRESET")
		EXTRA_OPTS=(-tag:v hvc1)
	elif [ "$ENCODER" = "h264_qsv" ]; then
		PRESET="slow"
		PIX_FMT="nv12"
		ENCODER_OPTS=(-c:v h264_qsv -b:v "${TARGET_BITRATE}" -preset "$PRESET" -pix_fmt "$PIX_FMT")
	elif [ "$ENCODER" = "h264_vaapi" ]; then
		# VAAPI encoder for older Intel processors (fallback when QSV not available)
		# Use software decoding (VAAPI doesn't support all codecs like AV1) and VAAPI encoding
		# Convert to nv12 format and upload to VAAPI surface using filter
		# INPUT_OPTS left empty - use software decoding
		ENCODER_OPTS=(-vf "format=nv12,hwupload" -c:v h264_vaapi -b:v "${TARGET_BITRATE}")
	elif [ "$ENCODER" = "h264_nvenc" ]; then
		PRESET="slow"
		ENCODER_OPTS=(-c:v h264_nvenc -b:v "${TARGET_BITRATE}" -preset "$PRESET" -rc:v vbr)
	elif [ "$ENCODER" = "h264_videotoolbox" ]; then
		ENCODER_OPTS=(-c:v h264_videotoolbox -b:v "${TARGET_BITRATE}")
	elif [ "$ENCODER" = "h264_amf" ]; then
		PRESET="speed"
		ENCODER_OPTS=(-c:v h264_amf -b:v "${TARGET_BITRATE}" -quality "$PRESET")
	elif [ "$ENCODER" = "h264_v4l2m2m" ]; then
		# Raspberry Pi hardware encoder (V4L2 M2M)
		# Note: v4l2m2m doesn't support preset, just bitrate
		ENCODER_OPTS=(-c:v h264_v4l2m2m -b:v "${TARGET_BITRATE}")
	elif [ "$ENCODER" = "libx264" ]; then
		PRESET="medium"
		ENCODER_OPTS=(-c:v libx264 -b:v "${TARGET_BITRATE}" -preset "$PRESET")
	else
		echo "Unknown encoder: $ENCODER" >&2
		return 1
	fi
	
	# Common options for all encoders
	local HW_ACCEL=""
	if [ "$IS_HARDWARE" = "1" ]; then
		HW_ACCEL="(hardware accelerated)"
	fi
	
	echo "Converting video using $ENCODER $HW_ACCEL at bitrate ${TARGET_BITRATE}" >&2
	
	# For VAAPI encoders, we need to combine scale with the format/hwupload filter
	# Check if ENCODER_OPTS already contains a VAAPI filter (format=nv12,hwupload)
	local HAS_VAAPI_FILTER=0
	local VAAPI_FILTER_INDEX=-1
	for i in "${!ENCODER_OPTS[@]}"; do
		if [[ "${ENCODER_OPTS[$i]}" == "-vf" ]] && [[ "${ENCODER_OPTS[$((i+1))]}" =~ format=nv12,hwupload ]]; then
			HAS_VAAPI_FILTER=1
			VAAPI_FILTER_INDEX=$i
			break
		fi
	done
	
	# Preserve resolution using scale filter (most important hint for server re-encoding)
	if [ -n "$INPUT_WIDTH" ] && [ -n "$INPUT_HEIGHT" ] && [ "$INPUT_WIDTH" != "N/A" ] && [ "$INPUT_HEIGHT" != "N/A" ]; then
		if [ "$HAS_VAAPI_FILTER" -eq 1 ] && [ "$VAAPI_FILTER_INDEX" -ge 0 ]; then
			# For VAAPI: combine scale with format/hwupload filter
			# Replace the existing filter in ENCODER_OPTS with combined filter
			local VAAPI_FILTER="scale=${INPUT_WIDTH}:${INPUT_HEIGHT},format=nv12,hwupload"
			ENCODER_OPTS[$((VAAPI_FILTER_INDEX+1))]="$VAAPI_FILTER"
			echo "Preserving resolution with VAAPI: ${INPUT_WIDTH}x${INPUT_HEIGHT}" >&2
		fi
	fi
	
	# Build ffmpeg command with comprehensive aspect ratio and resolution preservation
	# This provides maximum hints to the blossom server for proper re-encoding
	# INPUT_OPTS must come before -i, ENCODER_OPTS and EXTRA_OPTS come after -i
	local FFMPEG_CMD=(-y "${INPUT_OPTS[@]}" -i "$WIN_INPUT" "${ENCODER_OPTS[@]}" "${EXTRA_OPTS[@]}")
	
	# For non-VAAPI encoders: add scale filter if not already in ENCODER_OPTS
	if [ -n "$INPUT_WIDTH" ] && [ -n "$INPUT_HEIGHT" ] && [ "$INPUT_WIDTH" != "N/A" ] && [ "$INPUT_HEIGHT" != "N/A" ]; then
		if [ "$HAS_VAAPI_FILTER" -eq 0 ]; then
			# For other encoders: add scale filter normally
			FFMPEG_CMD+=(-vf "scale=${INPUT_WIDTH}:${INPUT_HEIGHT}")
			echo "Preserving resolution: ${INPUT_WIDTH}x${INPUT_HEIGHT}" >&2
		fi
	fi
	
	# Set display aspect ratio (DAR) metadata (only if valid)
	# DAR must be in format "num:num" (e.g., "16:9") - ffmpeg also accepts decimal but we'll use ratio format
	if [ -n "$ASPECT_RATIO" ] && [ "$ASPECT_RATIO" != "N/A" ] && [[ "$ASPECT_RATIO" =~ ^[0-9]+:[0-9]+$ ]]; then
		FFMPEG_CMD+=(-aspect "$ASPECT_RATIO")
		echo "Setting display aspect ratio: $ASPECT_RATIO" >&2
	fi
	
	# Set sample aspect ratio (SAR) metadata (only if valid)
	if [ -n "$SAR" ] && [ "$SAR" != "N/A" ] && [[ "$SAR" =~ ^[0-9]+:[0-9]+$ ]]; then
		FFMPEG_CMD+=(-sar "$SAR")
		echo "Setting sample aspect ratio: $SAR" >&2
	fi
	
	FFMPEG_CMD+=(-movflags +faststart -c:a copy "$WIN_OUTPUT")
	
	# Debug: Print the full ffmpeg command
	echo "Debug: ffmpeg command: ffmpeg ${FFMPEG_CMD[*]}" >&2
	
	# Run ffmpeg conversion - capture output for error reporting
	local FFMPEG_OUTPUT
	FFMPEG_OUTPUT=$(ffmpeg "${FFMPEG_CMD[@]}" 2>&1)
	local FFMPEG_EXIT=$?
	
	if [ $FFMPEG_EXIT -eq 0 ] && [ -f "$OUTPUT_FILE" ]; then
		echo "Video conversion successful with $ENCODER" >&2
		return 0
	else
		echo "Video conversion failed with encoder $ENCODER" >&2
		# Show last few lines of error output for debugging
		if [ -n "$FFMPEG_OUTPUT" ]; then
			echo "ffmpeg error output:" >&2
			echo "$FFMPEG_OUTPUT" | tail -n 15 >&2
		fi
		return 1
	fi
}

# Function to download video from URL using yt-dlp
# Parameters:
#   $1: VIDEO_URL - URL to download
#   $2: HISTORY_FILE - path to history file
#   $3: CONVERT_VIDEO - 1 to convert, 0 otherwise
#   $4: USE_COOKIES_FF - 1 to use Firefox cookies, 0 otherwise
#   $5: COOKIES_FILE - path to cookies file (empty if not provided)
#   $6: APPEND_ORIGINAL_COMMENT - 1 to append, 0 otherwise
#   $7: DISABLE_HASH_CHECK - 1 to disable, 0 otherwise
#   $8: DESCRIPTION_CANDIDATE - current description candidate
#   $9: SOURCE_CANDIDATE - current source candidate
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
	local COOKIES_FILE="$5"
	local APPEND_ORIGINAL_COMMENT="$6"
	local DISABLE_HASH_CHECK="$7"
	local DESCRIPTION_CANDIDATE="$8"
	local SOURCE_CANDIDATE="$9"
	
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
	local WINFILE_INT=$(convert_path_for_tool "$OUT_FILE_INT")
	local WINFILE=$(convert_path_for_tool "$OUT_FILE")
	
	local FORMATS='bestvideo[codec^=hevc]+bestaudio/bestvideo[codec^=avc]+bestaudio/best[codec^=hevc]/best[codec^=avc]/bestvideo+bestaudio/best'
	if [ "$CONVERT_VIDEO" -eq 0 ]; then
		FORMATS='bestvideo[codec^=hevc]+bestaudio/bestvideo[codec^=avc]+bestaudio/best[codec^=hevc]/best[codec^=avc]/best'
	fi
	
	local YT_DLP_OPTS=()
	if [ -n "$COOKIES_FILE" ]; then
		# Use cookie file if provided (takes precedence over --firefox)
		# If cookies file is read-only, copy it to a writable temp location
		# (yt-dlp tries to save cookies back to the file)
		local COOKIES_FILE_TO_USE="$COOKIES_FILE"
		if [ -f "$COOKIES_FILE" ] && [ ! -w "$COOKIES_FILE" ]; then
			local TEMP_COOKIES=$(mktemp /tmp/cookies_XXXXXXXX.txt)
			cp "$COOKIES_FILE" "$TEMP_COOKIES"
			add_to_cleanup "$TEMP_COOKIES"
			COOKIES_FILE_TO_USE="$TEMP_COOKIES"
		fi
		local WIN_COOKIES_FILE=$(convert_path_for_tool "$COOKIES_FILE_TO_USE")
		YT_DLP_OPTS+=(--cookies "$WIN_COOKIES_FILE")
	elif [ "$USE_COOKIES_FF" -eq 1 ]; then
		YT_DLP_OPTS+=(--cookies-from-browser firefox)
	fi
	
	# Find yt-dlp command dynamically (check PATH first, then fallback to hardcoded path for Cygwin)
	local YT_DLP_CMD
	if command -v yt-dlp >/dev/null 2>&1; then
		YT_DLP_CMD="yt-dlp"
	elif [ -f "/usr/local/bin/yt-dlp" ]; then
		YT_DLP_CMD="/usr/local/bin/yt-dlp"
	else
		echo "Error: yt-dlp not found in PATH or at /usr/local/bin/yt-dlp" >&2
		return 1
	fi
	
	echo "yt-dlp stdout/stderr:" >&2
	"$YT_DLP_CMD" "${YT_DLP_OPTS[@]}" "$VIDEO_URL" -f "$FORMATS" -S ext:mp4:m4a --merge-output-format mp4 --write-description -o "$WINFILE_INT" 2>&1
	local YT_DLP_EXIT_CODE=$?
	
	if [ $YT_DLP_EXIT_CODE -eq 0 ] && [ -f "$OUT_FILE_INT" ]; then
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
		else
			download_video_ret_source="$SOURCE_CANDIDATE"
		fi
		
		# Calculate the sha256 hash
		local DOWNLOADED_FILE_HASH=$(sha256sum "$OUT_FILE_INT" | awk '{print $1}')
		echo "SHA256 hash: $DOWNLOADED_FILE_HASH"
		if check_history "$DOWNLOADED_FILE_HASH" "$HISTORY_FILE" "$DISABLE_HASH_CHECK"; then
			die "File hash already processed: $DOWNLOADED_FILE_HASH"
		fi
		
		# Check if the downloaded file is actually an image (yt-dlp sometimes downloads images as video.mp4)
		local MIME_TYPE=$(file --mime-type -b "$OUT_FILE_INT")
		if [[ "$MIME_TYPE" == image/* ]]; then
			echo "Detected downloaded file as image (MIME: $MIME_TYPE), skipping video conversion"
			
			# Determine extension based on mime type
			local EXT="jpg"
			if [[ "$MIME_TYPE" == "image/png" ]]; then
				EXT="png"
			elif [[ "$MIME_TYPE" == "image/gif" ]]; then
				EXT="gif"
			elif [[ "$MIME_TYPE" == "image/webp" ]]; then
				EXT="webp"
			fi
			
			# Rename the file
			local NEW_OUT_FILE="${VIDEO_TMPDIR}/image.${EXT}"
			mv "$OUT_FILE_INT" "$NEW_OUT_FILE"
			
			# Update return variables
			download_video_ret_files+=("$NEW_OUT_FILE")
			download_video_ret_captions+=("$file_caption")
			download_video_ret_success=0
			
			# Add to cleanup
			add_to_cleanup "$NEW_OUT_FILE"
			
			echo "Downloaded as image: '$NEW_OUT_FILE'"
			return 0
		fi
		
		# Detect and convert video codec if needed
		local VIDEO_CODEC=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 "$WINFILE_INT" 2>/dev/null)
		VIDEO_CODEC=$(echo "$VIDEO_CODEC" | tr -d '\r')
		echo "Video codec: '$VIDEO_CODEC'"
		
		if [ "$VIDEO_CODEC" != "h264" ] && [ "$VIDEO_CODEC" != "hevc" ]; then
			if [ "$CONVERT_VIDEO" -eq 1 ]; then
				echo "Converting $OUT_FILE_INT to compatible format (h264 or h265)"
				
				# Get source bitrate
				local BITRATE=$(ffprobe -v error -select_streams v:0 -show_entries stream=bit_rate -of csv=p=0 "$WINFILE_INT" 2>/dev/null)
				BITRATE=$(echo "$BITRATE" | tr -d '\r' | tr -cd '[:digit:]')
				
				if [[ "$BITRATE" =~ ^[0-9]+$ ]]; then
					echo "Source bitrate: ${BITRATE} bps"
					
					# Try conversion with fallback chain (if H265 enabled): h265 hardware > h264 hardware > h265 software > h264 software
					# If H265 disabled (default): h264 hardware > h264 software
					echo "Trying video encoders in priority order..."
					
					# Get list of available encoders in priority order
					# Use ENCODERS from environment/command line if set, otherwise auto-detect
					# ENABLE_H265 defaults to 0 (disabled, only H264)
					local ENABLE_H265="${ENABLE_H265:-0}"
					local ENCODERS_STR
					ENCODERS_STR=$(get_available_encoders_priority "${ENCODERS:-}" "$ENABLE_H265")
					local ENCODER_LIST_RESULT=$?
					
					if [ $ENCODER_LIST_RESULT -ne 0 ]; then
						echo "Error: No suitable video encoder found (h264 or h265 required)" >&2
						die "Cannot convert video: no compatible encoder available. Please install ffmpeg with h264/h265 support."
					fi
					
					# Deserialize encoder list
					local ENCODER_LIST=()
					eval "ENCODER_LIST=($ENCODERS_STR)"
					
					local CONVERSION_SUCCESS=0
					local LAST_ERROR=""
					
					# Try each encoder in order until one succeeds
					for ENCODER_SPEC in "${ENCODER_LIST[@]}"; do
						# Parse encoder spec: "encoder_name:type:hw"
						local ENCODER_NAME ENCODER_TYPE IS_HARDWARE
						ENCODER_NAME=$(echo "$ENCODER_SPEC" | cut -d: -f1)
						ENCODER_TYPE=$(echo "$ENCODER_SPEC" | cut -d: -f2)
						IS_HARDWARE=$(echo "$ENCODER_SPEC" | cut -d: -f3)
						
						if [ -z "$ENCODER_NAME" ] || [ -z "$ENCODER_TYPE" ]; then
							continue
						fi
						
						local HW_DESC="software"
						if [ "$IS_HARDWARE" = "1" ]; then
							HW_DESC="hardware-accelerated"
						fi
						
						echo "Trying encoder: $ENCODER_NAME ($ENCODER_TYPE, $HW_DESC)"
						
						# Try conversion with this encoder
						if convert_video_with_encoder "$OUT_FILE_INT" "$OUT_FILE" "$ENCODER_NAME" "$ENCODER_TYPE" "$IS_HARDWARE" "$BITRATE"; then
							if [ -f "$OUT_FILE" ]; then
								echo "Conversion successful with $ENCODER_NAME"
								download_video_ret_files+=("$OUT_FILE")
								download_video_ret_captions+=("$file_caption")
								CONVERSION_SUCCESS=1
								break
							else
								echo "Warning: Conversion reported success but output file not found, trying next encoder..." >&2
								LAST_ERROR="Conversion succeeded but output file not found"
							fi
						else
							echo "Encoder $ENCODER_NAME failed, trying next encoder..." >&2
							LAST_ERROR="Encoder $ENCODER_NAME failed"
							# Continue to next encoder
						fi
					done
					
					if [ $CONVERSION_SUCCESS -eq 0 ]; then
						echo "Error: All video encoders failed - cannot convert incompatible codec ($VIDEO_CODEC)" >&2
						echo "The video codec '$VIDEO_CODEC' is not compatible with iOS devices." >&2
						echo "Tried ${#ENCODER_LIST[@]} encoder(s), all failed. Last error: $LAST_ERROR" >&2
						die "Video conversion failed - cannot proceed with incompatible codec. Please ensure ffmpeg has working h264/h265 encoders."
					fi
				else
					echo "Error: Could not determine source bitrate for conversion" >&2
					echo "Cannot convert video codec '$VIDEO_CODEC' without knowing source bitrate." >&2
					echo "The video codec '$VIDEO_CODEC' is not compatible with iOS devices." >&2
					die "Cannot convert video: source bitrate could not be determined. Cannot proceed with incompatible codec."
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
			local WIN_TEST_TMPDIR=$(convert_path_for_tool "$TEST_TMPDIR")
			echo "Testing download: gallery-dl \"${URL_GALLERY_DL_PARAMS[@]}\" -f '{num}.{extension}' -D \"$WIN_TEST_TMPDIR\" --write-metadata \"$URL_NOSET\""
			echo "gallery-dl stdout/stderr:" >&2
			gallery-dl "${URL_GALLERY_DL_PARAMS[@]}" -f '{num}.{extension}' -D "$WIN_TEST_TMPDIR" --write-metadata "$URL_NOSET" 2>&1
			local GALLERY_DL_EXIT_CODE=$?
			if [ $GALLERY_DL_EXIT_CODE -eq 0 ] && [ "$(ls -A "$TEST_TMPDIR" 2>/dev/null)" ]; then
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
				local WIN_POSITION_TMPDIR=$(convert_path_for_tool "$POSITION_TMPDIR")
				# Add temp directory to cleanup list
				add_to_cleanup "$POSITION_TMPDIR"
				
				
				# Start gallery-dl and read its output line by line
				echo "Starting gallery-dl and reading output line-by-line..."
				
				# Use local variables (no files needed since we use process substitution, not pipe)
				local current_count=0
				
				# Run gallery-dl and read its output line by line using process substitution
				# Process substitution doesn't create a subshell, so variables are accessible
				# When we break out of the loop, gallery-dl will receive SIGPIPE on its next write
				echo "gallery-dl stdout/stderr:" >&2
				while IFS= read -r line; do
					# Log all lines from gallery-dl for debugging (to stderr)
					echo "$line" >&2
					
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
								echo "Metadata file: $meta"
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
					local WIN_MATCHING_FILE_DIR=$(convert_path_for_tool "$MATCHING_FILE_DIR")
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
		local WIN_IMAGES_TMPDIR=$(convert_path_for_tool "$IMAGES_TMPDIR")
		# Add temp directory to cleanup list
		add_to_cleanup "$IMAGES_TMPDIR"
		
		echo "gallery-dl stdout/stderr:" >&2
		gallery-dl "${URL_GALLERY_DL_PARAMS[@]}" -f '{num}.{extension}' -D "$WIN_IMAGES_TMPDIR" --write-metadata "$PROCESSED_URL" 2>&1
		local GALLERY_DL_EXIT_CODE=$?
		
		if [ $GALLERY_DL_EXIT_CODE -eq 0 ] && [ "$(ls -A "$IMAGES_TMPDIR" 2>/dev/null)" ]; then
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
		else
			download_images_ret_source="$SOURCE_CANDIDATE"
		fi
		download_images_ret_success=0
	fi
}

# Function to download Facebook image using curl and parse og:image/twitter:image meta tags
# Parameters:
#   $1: FACEBOOK_URL - Facebook URL to download
#   $2: APPEND_ORIGINAL_COMMENT - 1 to append original comment, 0 otherwise
#   $3: DESCRIPTION_CANDIDATE - description candidate to use
#   $4: SOURCE_CANDIDATE - source candidate to use
# Return variables (set at end of function):
#   download_facebook_og_ret_files - array of downloaded files
#   download_facebook_og_ret_captions - array of captions (one per file)
#   download_facebook_og_ret_source - source to set (empty if should keep current)
#   download_facebook_og_ret_success - 0 on success, 1 on failure
#   download_facebook_og_ret_error - error message if download failed (empty on success)
resolve_mobile_shared_url() {
	local MOBILE_SHARED_URL="$1"
	local GALLERY_DL_PARAMS_STR="$2"
	
	# Return variables (global, set at end of function)
	resolve_mobile_shared_url_ret_photo_url=""
	resolve_mobile_shared_url_ret_success=1
	resolve_mobile_shared_url_ret_error=""
	
	# Check if URL matches mobile shared format (multiple chars after /share/, not single letter paths like /r/, /v/)
	# Also accept /share/p/... format
	if [[ ! "$MOBILE_SHARED_URL" =~ ^https?://(www\.)?facebook\.com/share/(p/)?[A-Za-z0-9]{2,} ]]; then
		resolve_mobile_shared_url_ret_error="URL does not match mobile shared format (facebook.com/share/... or share/p/... with multiple chars)"
		return 1
	fi
	
	echo "Processing mobile shared URL: $MOBILE_SHARED_URL"
	
	# Step 1: Use curl to get the redirect URL
	echo "Step 1: Getting redirect URL with curl..."
	local REDIRECT_URL=""
	
	# First try: Use curl -w to get the effective (final) URL after following redirects
	REDIRECT_URL=$(curl -s -L -I -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" "$MOBILE_SHARED_URL" -o /dev/null -w "%{url_effective}" 2>/dev/null)
	
	# If that didn't work, try with verbose output to extract Location headers
	if [ -z "$REDIRECT_URL" ] || [ "$REDIRECT_URL" = "$MOBILE_SHARED_URL" ]; then
		# Use curl with -L to follow redirects and -v to see them, then extract final URL
		local CURL_OUTPUT=$(curl -s -L -v -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" "$MOBILE_SHARED_URL" -o /dev/null 2>&1)
		
		# Extract the final URL from curl output (look for "< Location: " or final URL)
		# curl shows redirects like: < Location: https://www.facebook.com/...
		if [[ "$CURL_OUTPUT" =~ \<\ Location:\ ([^\r\n]+) ]]; then
			REDIRECT_URL="${BASH_REMATCH[1]}"
			# Remove trailing whitespace
			REDIRECT_URL=$(echo "$REDIRECT_URL" | sed 's/[[:space:]]*$//')
		fi
		
		# If no Location header found, try to extract from verbose output
		if [ -z "$REDIRECT_URL" ]; then
			# Look for "> GET" lines which show the final request
			local LAST_GET_LINE=$(echo "$CURL_OUTPUT" | grep "> GET" | tail -1)
			if [[ "$LAST_GET_LINE" =~ \>\ GET\ ([^\ ]+) ]]; then
				local PATH_PART="${BASH_REMATCH[1]}"
				REDIRECT_URL="https://www.facebook.com$PATH_PART"
			fi
		fi
		
		if [ -z "$REDIRECT_URL" ]; then
			resolve_mobile_shared_url_ret_error="Could not determine redirect URL from curl output"
			echo "Debug: curl output was:" >&2
			echo "$CURL_OUTPUT" >&2
			return 1
		fi
	fi
	
	echo "Redirect URL: $REDIRECT_URL"
	
	# Step 2: Try gallery-dl with -v --range 1 --no-download to see debug output
	echo "Step 2: Running gallery-dl with debug output to find photo URL..."
	
	# Reconstruct GALLERY_DL_PARAMS array from string
	local GALLERY_DL_PARAMS=()
	eval "GALLERY_DL_PARAMS=($GALLERY_DL_PARAMS_STR)"
	
	# Run gallery-dl with verbose output and no download
	local GALLERY_DL_OUTPUT=$(gallery-dl "${GALLERY_DL_PARAMS[@]}" -v --range 1 --no-download "$REDIRECT_URL" 2>&1)
	local GALLERY_DL_EXIT_CODE=$?
	
	echo "gallery-dl debug output:" >&2
	echo "$GALLERY_DL_OUTPUT" >&2
	
	# Step 3: Parse output to find photo URL
	# Look for lines like:
	# [urllib3.connectionpool][debug] https://www.facebook.com:443 "GET /photo/?fbid=25751404924484140&set=pcb.25751405024484130 HTTP/11" 200 None
	local PHOTO_URL=""
	
	# Extract the last GET request that matches /photo/?fbid= pattern
	local PHOTO_LINES=$(echo "$GALLERY_DL_OUTPUT" | grep -E 'GET /photo/\?fbid=[0-9]+&set=' | tail -1)
	if [[ "$PHOTO_LINES" =~ GET\ (/photo/\?fbid=[0-9]+&set=[^\ ]+) ]]; then
		local PHOTO_PATH="${BASH_REMATCH[1]}"
		# Remove quotes if present
		PHOTO_PATH=$(echo "$PHOTO_PATH" | sed 's/"//g')
		PHOTO_URL="https://www.facebook.com$PHOTO_PATH"
		echo "Found photo URL from debug output: $PHOTO_URL"
	fi
	
	if [ -z "$PHOTO_URL" ]; then
		# Fallback: Try to parse the redirect URL to extract permalink ID
		echo "Could not find photo URL in gallery-dl debug output, trying to parse redirect URL..."
		
		# Check if redirect URL matches /groups/XXXX/permalink/YYYYY pattern
		if [[ "$REDIRECT_URL" =~ /groups/[0-9]+/permalink/([0-9]+) ]]; then
			local PERMALINK_ID="${BASH_REMATCH[1]}"
			echo "Found permalink ID in redirect URL: $PERMALINK_ID"
			
			# Construct media set URL: https://www.facebook.com/media/set/?set=pcb.PERMALINK_ID
			PHOTO_URL="https://www.facebook.com/media/set/?set=pcb.$PERMALINK_ID"
			echo "Constructed media set URL from permalink: $PHOTO_URL"
		else
			resolve_mobile_shared_url_ret_error="Could not find photo URL in gallery-dl debug output and redirect URL does not match /groups/XXXX/permalink/YYYYY pattern"
			return 1
		fi
	fi
	
	resolve_mobile_shared_url_ret_photo_url="$PHOTO_URL"
	resolve_mobile_shared_url_ret_success=0
	return 0
}

download_facebook_og_image() {
	local FACEBOOK_URL="$1"
	local APPEND_ORIGINAL_COMMENT="$2"
	local DESCRIPTION_CANDIDATE="$3"
	local SOURCE_CANDIDATE="$4"
	
	# Return variables (global, set at end of function)
	download_facebook_og_ret_files=()
	download_facebook_og_ret_captions=()
	download_facebook_og_ret_source=""
	download_facebook_og_ret_success=1
	download_facebook_og_ret_error=""
	
	# Check if URL matches Facebook patterns
	# Accept: share/p/..., groups/.../permalink/..., and share/[A-Za-z0-9]{2,} (mobile shared)
	if [[ ! "$FACEBOOK_URL" =~ ^https?://(www\.)?facebook\.com/(share/p/[^/]+|groups/[^/]+/permalink/[^/]+|share/[A-Za-z0-9]{2,}) ]]; then
		download_facebook_og_ret_error="URL does not match Facebook share/p, groups/permalink, or mobile share pattern"
		return 1
	fi
	
	echo "Attempting to download Facebook page using curl: $FACEBOOK_URL"
	
	# Create temporary directory for HTML and image
	local TMPDIR=$(mktemp -d /tmp/facebook_og_XXXXXXXX)
	add_to_cleanup "$TMPDIR"
	
	local HTML_FILE="${TMPDIR}/page.html"
	local IMAGE_FILE="${TMPDIR}/image.jpg"
	
	# Download the HTML page using curl
	echo "Downloading HTML page with curl..."
	if ! curl -s -L -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" "$FACEBOOK_URL" -o "$HTML_FILE" 2>&1; then
		download_facebook_og_ret_error="Failed to download Facebook page with curl"
		return 1
	fi
	
	if [ ! -f "$HTML_FILE" ] || [ ! -s "$HTML_FILE" ]; then
		download_facebook_og_ret_error="Downloaded HTML file is empty or missing"
		return 1
	fi
	
	# Parse for og:image or twitter:image meta tag
	local IMAGE_URL=""
	
	# Try og:image first - extract just the meta tag that has property="og:image" (not og:image:something)
	# Since HTML might be minified on one line, we need to extract just the specific meta tag
	# Pattern: <meta ... property="og:image" ... content="URL" ... />
	local META_TAG=$(grep -oE '<meta[^>]*property=["'\'']og:image["'\''][^>]*>' "$HTML_FILE" | grep -v 'og:image:' | head -1)
	
	if [ -z "$META_TAG" ]; then
		# Try with single quotes
		META_TAG=$(grep -oE "<meta[^>]*property=['\"]og:image['\"][^>]*>" "$HTML_FILE" | grep -v 'og:image:' | head -1)
	fi
	
	if [ -n "$META_TAG" ]; then
		echo "Found og:image meta tag: $META_TAG" >&2
		# Extract content attribute value from this specific tag
		# Try double quotes first: content="URL"
		if [[ "$META_TAG" =~ content\s*=\s*\"([^\"]+)\" ]]; then
			IMAGE_URL="${BASH_REMATCH[1]}"
		# Try single quotes: content='URL'
		elif [[ "$META_TAG" =~ content\s*=\s*\'([^\']+)\' ]]; then
			IMAGE_URL="${BASH_REMATCH[1]}"
		# Try without quotes (rare but possible): content=URL
		elif [[ "$META_TAG" =~ content\s*=\s*([^\s\>]+) ]]; then
			IMAGE_URL="${BASH_REMATCH[1]}"
		fi
		
		# Convert &amp; to & in the image URL immediately after extraction
		if [ -n "$IMAGE_URL" ]; then
			IMAGE_URL=$(echo "$IMAGE_URL" | sed "s/&amp;/\&/g")
		fi
		
		# Validate it's a URL
		if [[ ! "$IMAGE_URL" =~ ^https?:// ]]; then
			IMAGE_URL=""
		fi
	fi
	
	# If not found, try twitter:image
	if [ -z "$IMAGE_URL" ]; then
		local TWITTER_TAG=$(grep -oE '<meta[^>]*name=["'\'']twitter:image["'\''][^>]*>' "$HTML_FILE" | head -1)
		
		if [ -z "$TWITTER_TAG" ]; then
			# Try with single quotes
			TWITTER_TAG=$(grep -oE "<meta[^>]*name=['\"]twitter:image['\"][^>]*>" "$HTML_FILE" | head -1)
		fi
		
		if [ -n "$TWITTER_TAG" ]; then
			echo "Found twitter:image meta tag: $TWITTER_TAG" >&2
			# Extract content attribute value
			if [[ "$TWITTER_TAG" =~ content\s*=\s*\"([^\"]+)\" ]]; then
				IMAGE_URL="${BASH_REMATCH[1]}"
			elif [[ "$TWITTER_TAG" =~ content\s*=\s*\'([^\']+)\' ]]; then
				IMAGE_URL="${BASH_REMATCH[1]}"
			elif [[ "$TWITTER_TAG" =~ content\s*=\s*([^\s\>]+) ]]; then
				IMAGE_URL="${BASH_REMATCH[1]}"
			fi
			
			# Convert &amp; to & in the image URL immediately after extraction
			if [ -n "$IMAGE_URL" ]; then
				IMAGE_URL=$(echo "$IMAGE_URL" | sed "s/&amp;/\&/g")
			fi
			
			# Validate it's a URL
			if [[ ! "$IMAGE_URL" =~ ^https?:// ]]; then
				IMAGE_URL=""
			fi
		fi
	fi
	
	if [ -z "$IMAGE_URL" ] || [[ ! "$IMAGE_URL" =~ ^https?:// ]]; then
		download_facebook_og_ret_error="Could not find og:image or twitter:image meta tag with valid URL in HTML"
		return 1
	fi
	
	# URL should already have &amp; converted to &, but do it again to be safe
	IMAGE_URL=$(echo "$IMAGE_URL" | sed "s/&amp;/\&/g")
	
	# Remove size constraints from URL (e.g., &ctp=p600x600) to get higher resolution
	# Remove &ctp=... pattern (can be any value like p600x600, p1080x1080, etc.)
	IMAGE_URL=$(echo "$IMAGE_URL" | sed 's/[&?]ctp=[^&]*//g')
	# Also handle if it was the first parameter and left a trailing ? or &
	IMAGE_URL=$(echo "$IMAGE_URL" | sed 's/?&/\?/g' | sed 's/&&/\&/g' | sed 's/?$//')
	
	echo "Found image URL: $IMAGE_URL"
	
	# Download the image using curl
	echo "Downloading image with curl..."
	if ! curl -s -L -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" "$IMAGE_URL" -o "$IMAGE_FILE" 2>&1; then
		download_facebook_og_ret_error="Failed to download image from $IMAGE_URL"
		return 1
	fi
	
	if [ ! -f "$IMAGE_FILE" ] || [ ! -s "$IMAGE_FILE" ]; then
		download_facebook_og_ret_error="Downloaded image file is empty or missing"
		return 1
	fi
	
	# Verify the downloaded file is actually an image
	local MIME_TYPE=$(file --mime-type -b "$IMAGE_FILE" 2>/dev/null)
	if [[ ! "$MIME_TYPE" =~ ^image/ ]]; then
		download_facebook_og_ret_error="Downloaded file is not an image (MIME type: ${MIME_TYPE:-unknown}). This might be an error page or invalid content."
		return 1
	fi
	echo "Verified downloaded file is an image (MIME type: $MIME_TYPE)"
	
	# Determine file extension from image URL or MIME type
	local EXT="jpg"
	if [[ "$IMAGE_URL" =~ \.(jpg|jpeg|png|webp|gif)(\?|$) ]]; then
		EXT="${BASH_REMATCH[1]}"
		# Normalize jpeg to jpg
		if [ "$EXT" = "jpeg" ]; then
			EXT="jpg"
		fi
	else
		# Try to detect from file command (MIME_TYPE already set above)
		if [[ "$MIME_TYPE" == image/png ]]; then
			EXT="png"
		elif [[ "$MIME_TYPE" == image/webp ]]; then
			EXT="webp"
		elif [[ "$MIME_TYPE" == image/gif ]]; then
			EXT="gif"
		elif [[ "$MIME_TYPE" == image/jpeg ]]; then
			EXT="jpg"
		fi
	fi
	
	# Rename file with correct extension if needed
	local FINAL_IMAGE_FILE="${TMPDIR}/image.${EXT}"
	if [ "$IMAGE_FILE" != "$FINAL_IMAGE_FILE" ]; then
		mv "$IMAGE_FILE" "$FINAL_IMAGE_FILE"
	fi
	
	# Parse for og:description or twitter:description as comment
	local EXTRACTED_CAPTION=""
	if [ "$APPEND_ORIGINAL_COMMENT" -eq 1 ]; then
		# Try og:description first
		local DESC_LINE=$(grep -i '<meta' "$HTML_FILE" | grep -i 'property' | grep -i 'og:description' | grep -i 'content' | head -1)
		if [ -n "$DESC_LINE" ]; then
			# Extract content attribute value
			if [[ "$DESC_LINE" =~ content\s*=\s*\"([^\"]+)\" ]]; then
				EXTRACTED_CAPTION="${BASH_REMATCH[1]}"
			elif [[ "$DESC_LINE" =~ content\s*=\s*\'([^\']+)\' ]]; then
				EXTRACTED_CAPTION="${BASH_REMATCH[1]}"
			elif [[ "$DESC_LINE" =~ content\s*=\s*([^\s\>]+) ]]; then
				EXTRACTED_CAPTION="${BASH_REMATCH[1]}"
			fi
		fi
		
		# If not found, try twitter:description
		if [ -z "$EXTRACTED_CAPTION" ]; then
			local TWITTER_DESC_LINE=$(grep -i '<meta' "$HTML_FILE" | grep -i 'name' | grep -i 'twitter:description' | grep -i 'content' | head -1)
			if [ -n "$TWITTER_DESC_LINE" ]; then
				# Extract content attribute value
				if [[ "$TWITTER_DESC_LINE" =~ content\s*=\s*\"([^\"]+)\" ]]; then
					EXTRACTED_CAPTION="${BASH_REMATCH[1]}"
				elif [[ "$TWITTER_DESC_LINE" =~ content\s*=\s*\'([^\']+)\' ]]; then
					EXTRACTED_CAPTION="${BASH_REMATCH[1]}"
				elif [[ "$TWITTER_DESC_LINE" =~ content\s*=\s*([^\s\>]+) ]]; then
					EXTRACTED_CAPTION="${BASH_REMATCH[1]}"
				fi
			fi
		fi
		
		# Decode HTML entities
		if [ -n "$EXTRACTED_CAPTION" ]; then
			# First decode common named entities (must be before &amp;)
			EXTRACTED_CAPTION=$(echo "$EXTRACTED_CAPTION" | sed 's/&lt;/</g' | sed 's/&gt;/>/g' | sed 's/&quot;/"/g' | sed "s/&#39;/'/g" | sed 's/&nbsp;/ /g')
			# Decode hex entities (&#xXXXX; format) - handle common emoji and characters
			# This is a basic implementation - for full support, would need perl/python
			EXTRACTED_CAPTION=$(echo "$EXTRACTED_CAPTION" | sed 's/&#x2764;&#xfe0f;/❤️/g' | sed 's/&#x2764;/❤/g')
			# Decode numeric entities (&#NNN; format) - basic support
			# Finally decode &amp; (must be last)
			EXTRACTED_CAPTION=$(echo "$EXTRACTED_CAPTION" | sed 's/&amp;/&/g')
		fi
	fi
	
	# Build caption
	local file_caption=$(build_caption "$DESCRIPTION_CANDIDATE" "$EXTRACTED_CAPTION" "$APPEND_ORIGINAL_COMMENT")
	
	# Set return variables
	download_facebook_og_ret_files+=("$FINAL_IMAGE_FILE")
	download_facebook_og_ret_captions+=("$file_caption")
	
	if [ -z "$SOURCE_CANDIDATE" ]; then
		download_facebook_og_ret_source="$FACEBOOK_URL"
	else
		download_facebook_og_ret_source="$SOURCE_CANDIDATE"
	fi
	
	download_facebook_og_ret_success=0
	echo "Successfully downloaded Facebook image: $FINAL_IMAGE_FILE"
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
	
	if [ ! -f "$FILE" ]; then
		echo "File does not exist: $FILE" >&2
		return 1
	fi
	
	echo "Uploading $FILE to file-drop server: $FILE_DROP_URL" >&2
	local upload_output=$(curl -s -X POST -F "file=@$FILE" "$FILE_DROP_URL" 2>&1)
	local RESULT=$?
	
	if [ $RESULT -ne 0 ]; then
		echo "Failed to upload file $FILE to file-drop server: $upload_output" >&2
		return 1
	fi
	
	# Check if output is valid JSON
	if ! echo "$upload_output" | jq . >/dev/null 2>&1; then
		echo "Invalid JSON response from file-drop server: $upload_output" >&2
		return 1
	fi
	
	local file_url=$(echo "$upload_output" | jq -r '.url')
	if [ -z "$file_url" ] || [ "$file_url" == "null" ]; then
		echo "Failed to extract URL from file-drop response: $upload_output" >&2
		return 1
	fi
	
	# Replace URL prefix if URL_PREFIX is set
	if [ -n "$URL_PREFIX" ]; then
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
	
	local FILE_WIN=$(convert_path_for_tool "$FILE")
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
		# It's a URL
		# Special handling for Instagram story URLs with story_media_id parameter
		if [[ "$MEDIA_FILE" =~ ^https?://.*instagram\.com/s/.*story_media_id=([^&]+) ]]; then
			# Extract story_media_id value from URL
			local STORY_MEDIA_ID=$(echo "$MEDIA_FILE" | sed -n 's/.*story_media_id=\([^&]*\).*/\1/p')
			if [ -n "$STORY_MEDIA_ID" ]; then
				echo "$STORY_MEDIA_ID"
				return
			fi
		fi
		
		# For other URLs, normalize first to get clean URL
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
	
	# Check if filename is a simple 1-2 digit number (with optional extension)
	# If so, skip filename check and rely only on hash check later
	if [[ ! "$FILE_NAME" =~ ^[0-9]{1,2}(\.[a-zA-Z0-9]+)?$ ]]; then
		if check_history "$FILE_NAME" "$HISTORY_FILE" "$DISABLE_HASH_CHECK"; then
			# Found in history - return filename
			echo "$FILE_NAME"
			return 1  # Found in history - should exit
		fi
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
	echo "  -p, --profile     Override config and history file names with specified profile"
	echo "                    If not specified, uses script filename to determine profile name"
	echo "  -cookies, --cookies FILE  Use cookies from specified file (Mozilla/Netscape format)"
	echo "                    Takes precedence over --firefox option"
	echo "  --firefox         Use cookies from Firefox browser"
	echo "  --encoders LIST   Comma-separated list of video encoders to use (e.g., libx264,libx265)"
	echo "                    If not specified, automatically detects and uses available encoders"
	echo "                    Supported encoders: libx264, libx265, hevc_qsv, h264_qsv,"
	echo "                    hevc_nvenc, h264_nvenc, hevc_amf, h264_amf, hevc_videotoolbox, h264_videotoolbox"
	echo "                    Can also be set via ENCODERS environment variable in config file"
	echo "  --enable-h265     Enable HEVC/H265 codecs (disabled by default, only H264 is used)"
	echo "                    Can also be set via ENABLE_H265=1 environment variable in config file"
	echo "  --file-drop URL  Use file-drop server for uploads (e.g., http://192.168.31.103:3232/upload)"
	echo "                    If file-drop fails, falls back to blossom servers"
	echo "                    Can also be set via FILE_DROP_URL environment variable in config file"
	echo "  --file-drop-url-prefix PREFIX  Replace https://dweb.link/ prefix in file-drop URLs"
	echo "                                 with custom prefix (e.g., https://gateway.example.com)"
	echo "                                 Can also be set via FILE_DROP_URL_PREFIX environment variable"
	echo "  --nsfw              Mark the post as NSFW by adding content-warning tag"
	echo "                    Can also be set via NSFW=1 environment variable in config file"
	echo "                    Automatically enabled if #NSFW or #nsfw hashtag is found in content"
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

# Function to get history file path
# Parameters:
#   $1: PROFILE_NAME - profile name to use for history file
# Return variables:
#   get_script_metadata_ret_history_file - history file path
get_script_metadata() {
	local PROFILE_PARAM="$1"
	# History file is stored in the same directory as the env file (~/.nostr/${PROFILE_NAME})
	local HISTORY_FILE="$HOME/.nostr/${PROFILE_PARAM}.history"
	
	get_script_metadata_ret_history_file="$HISTORY_FILE"
}

# Function to validate configuration (history file and keys)
# Parameters:
#   $1: HISTORY_FILE - path to history file
#   $2: NSEC_KEY - NSEC key value (may be empty)
#   $3: KEY - default key value (may be empty)
#   $4: NCRYPT_KEY - NCRYPT key value (may be empty)
# Returns: Dies on error, returns nothing on success
validate_configuration() {
	local HISTORY_FILE="$1"
	local NSEC_KEY="$2"
	local KEY="$3"
	local NCRYPT_KEY="$4"
	
	# Create history file if it doesn't exist
if [ ! -f "$HISTORY_FILE" ]; then
		# Ensure the directory exists
		local HISTORY_DIR=$(dirname "$HISTORY_FILE")
		if [ ! -d "$HISTORY_DIR" ]; then
			mkdir -p "$HISTORY_DIR" || die "Failed to create history directory: $HISTORY_DIR"
		fi
		# Create empty history file
		touch "$HISTORY_FILE" || die "Failed to create history file: $HISTORY_FILE"
	fi

if [[ -z "$NSEC_KEY" && -z "$KEY" && -z "$NCRYPT_KEY" ]]; then
		die "Error: No key variable is set. Please set NSEC_KEY, KEY, or NCRYPT_KEY"
	fi
}

# Function to process relays and blossoms by combining defaults with EXTRA_* variables
# Parameters:
#   $1: EXTRA_RELAYS_STR - serialized array of extra relays
#   $2: EXTRA_BLOSSOMS_STR - serialized array of extra blossoms
# Return variables:
#   process_relays_and_blossoms_ret_relays_list - combined relays as string
#   process_relays_and_blossoms_ret_blossoms_list - combined blossoms as serialized array
process_relays_and_blossoms() {
	local EXTRA_RELAYS_STR="$1"
	local EXTRA_BLOSSOMS_STR="$2"
	
	# Deserialize arrays
	local EXTRA_RELAYS=()
	local EXTRA_BLOSSOMS=()
	if [ -n "$EXTRA_RELAYS_STR" ]; then
		eval "EXTRA_RELAYS=($EXTRA_RELAYS_STR)"
	fi
	if [ -n "$EXTRA_BLOSSOMS_STR" ]; then
		eval "EXTRA_BLOSSOMS=($EXTRA_BLOSSOMS_STR)"
	fi
	
	# Process RELAYS
	local RELAYS_LIST="$RELAYS"
	if [[ ${#EXTRA_RELAYS[@]} -gt 0 ]]; then
		local RELAY
	for RELAY in "${EXTRA_RELAYS[@]}"; do
			RELAYS_LIST="$RELAYS_LIST $RELAY"
	done
fi

	# Process BLOSSOMS - filter out empty entries
	local BLOSSOMS_LIST=()
	# Filter BLOSSOMS array to remove empty entries
	for BLOSSOM in "${BLOSSOMS[@]}"; do
		# Remove quotes if present and check if non-empty
		BLOSSOM=$(echo "$BLOSSOM" | sed "s/^['\"]//;s/['\"]$//")
		if [ -n "$BLOSSOM" ]; then
			BLOSSOMS_LIST+=("$BLOSSOM")
		fi
	done
	
	# Add EXTRA_BLOSSOMS if any, also filtering out empty entries
	if [[ ${#EXTRA_BLOSSOMS[@]} -gt 0 ]]; then
		local EXTRA_FILTERED=()
		for BLOSSOM in "${EXTRA_BLOSSOMS[@]}"; do
			# Remove quotes if present and check if non-empty
			BLOSSOM=$(echo "$BLOSSOM" | sed "s/^['\"]//;s/['\"]$//")
			if [ -n "$BLOSSOM" ]; then
				EXTRA_FILTERED+=("$BLOSSOM")
			fi
		done
		if [[ ${#EXTRA_FILTERED[@]} -gt 0 ]]; then
			BLOSSOMS_LIST=("${EXTRA_FILTERED[@]}" "${BLOSSOMS_LIST[@]}")
		fi
	fi
	
	# Return via return variables
	process_relays_and_blossoms_ret_relays_list="$RELAYS_LIST"
	process_relays_and_blossoms_ret_blossoms_list=$(serialize_array "${BLOSSOMS_LIST[@]}")
}

# Function to prepare gallery-dl parameters
# Parameters:
#   $1: USE_COOKIES_FF - 1 to use Firefox cookies, 0 otherwise
#   $2: COOKIES_FILE - path to cookies file (empty if not provided)
# Return variables:
#   prepare_gallery_dl_params_ret_params - serialized array of gallery-dl parameters
prepare_gallery_dl_params() {
	local USE_COOKIES_FF="$1"
	local COOKIES_FILE="$2"
	
	local GALLERY_DL_PARAMS=()
	if [ -n "$COOKIES_FILE" ]; then
		# Use cookie file if provided (takes precedence over --firefox)
		# If cookies file is read-only, copy it to a writable temp location
		# (gallery-dl may try to save cookies back to the file)
		local COOKIES_FILE_TO_USE="$COOKIES_FILE"
		if [ -f "$COOKIES_FILE" ] && [ ! -w "$COOKIES_FILE" ]; then
			local TEMP_COOKIES=$(mktemp /tmp/cookies_XXXXXXXX.txt)
			cp "$COOKIES_FILE" "$TEMP_COOKIES"
			add_to_cleanup "$TEMP_COOKIES"
			COOKIES_FILE_TO_USE="$TEMP_COOKIES"
		fi
		local WIN_COOKIES_FILE=$(convert_path_for_tool "$COOKIES_FILE_TO_USE")
		GALLERY_DL_PARAMS+=(--cookies "$WIN_COOKIES_FILE")
	elif [ "$USE_COOKIES_FF" -eq 1 ]; then
		GALLERY_DL_PARAMS+=(--cookies-from-browser firefox)
	fi
	GALLERY_DL_PARAMS+=(--user-agent "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:120.0) Gecko/20100101 Firefox/120.0")
	
	prepare_gallery_dl_params_ret_params=$(serialize_array "${GALLERY_DL_PARAMS[@]}")
}

# Function to parse command-line arguments
# Parameters:
#   $@ - all command-line arguments (will be shifted as arguments are processed)
# Return variables:
#   parse_command_line_ret_media_files - serialized array of media files/URLs
#   parse_command_line_ret_convert_video - 1 to convert, 0 otherwise
#   parse_command_line_ret_send_to_relay - 1 to send, 0 otherwise
#   parse_command_line_ret_disable_hash_check - 1 to disable, 0 otherwise
#   parse_command_line_ret_max_file_search - maximum files to search
#   parse_command_line_ret_pow_diff - proof of work difficulty
#   parse_command_line_ret_append_original_comment - 1 to append, 0 otherwise
#   parse_command_line_ret_use_cookies_ff - 1 to use Firefox cookies, 0 otherwise
#   parse_command_line_ret_cookies_file - path to cookies file (empty if not provided)
#   parse_command_line_ret_display_source - 1 to display, 0 otherwise
#   parse_command_line_ret_password - password value
#   parse_command_line_ret_description_candidate - description text
#   parse_command_line_ret_source_candidate - source text
#   parse_command_line_ret_profile_name - profile name if -p option was used
#   parse_command_line_ret_encoders - comma-separated list of encoder names if --encoders option was used
#   parse_command_line_ret_file_drop_url - file-drop server URL if --file-drop option was used
#   parse_command_line_ret_file_drop_url_prefix - URL prefix if --file-drop-url-prefix option was used
#   parse_command_line_ret_enable_h265 - 1 if --enable-h265 was used, 0 otherwise
#   parse_command_line_ret_nsfw - 1 if --nsfw was used, 0 otherwise
# Side effects: Also exports PROFILE_NAME as a global variable for early use
parse_command_line() {
	# Initialize default values (hardcoded defaults, NOT from environment)
	# Environment variables will be merged later after loading the profile file
	local CONVERT_VIDEO=1
	local SEND_TO_RELAY=1
	local DISABLE_HASH_CHECK=0
	local MAX_FILE_SEARCH=10
	local POW_DIFF=20
	local APPEND_ORIGINAL_COMMENT=1
	local USE_COOKIES_FF=0
	local COOKIES_FILE=""
	local DISPLAY_SOURCE=0
	local PASSWORD=""
	local PROFILE_NAME=""
	local USER_ENCODERS=""
	local FILE_DROP_URL=""
	local FILE_DROP_URL_PREFIX=""
	local ENABLE_H265=0
	local NSFW=0
	
	local ALL_MEDIA_FILES=()
	local DESCRIPTION_CANDIDATE=""
	local SOURCE_CANDIDATE=""
	
	local PARAM
	local MIME_TYPE
	local url

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
	elif [[ "$PARAM" == "--cookies" || "$PARAM" == "-cookies" ]]; then
		COOKIES_FILE="$2"
		if [ -z "$COOKIES_FILE" ]; then
			echo "Cookie file path is required after --cookies option"
			exit 1
		fi
		if [ ! -f "$COOKIES_FILE" ]; then
			echo "Cookie file does not exist: $COOKIES_FILE"
			exit 1
		fi
		shift  # shift to remove the cookie file path from the params
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
	elif [[ "$PARAM" == "--profile" || "$PARAM" == "-p" ]]; then
		PROFILE_NAME="$2"
		if [ -z "$PROFILE_NAME" ]; then
			echo "Profile name is required after -p/--profile option"
			exit 1
		fi
		shift  # shift to remove the profile name from the params
	elif [[ "$PARAM" == "--max-file-search" || "$PARAM" == "-max-file-search" ]]; then
		MAX_FILE_SEARCH="$2"
		if [ -z "$MAX_FILE_SEARCH" ] || ! [[ "$MAX_FILE_SEARCH" =~ ^[0-9]+$ ]]; then
			echo "Invalid value for --max-file-search: $MAX_FILE_SEARCH (must be a number)"
			exit 1
		fi
		shift  # shift to remove the value from the params
	elif [[ "$PARAM" == "--encoders" || "$PARAM" == "-encoders" ]]; then
		USER_ENCODERS="$2"
		if [ -z "$USER_ENCODERS" ]; then
			echo "Encoder list is required after --encoders option (comma-separated, e.g., libx264,libx265)"
			exit 1
		fi
		shift  # shift to remove the encoder list from the params
	elif [[ "$PARAM" == "--file-drop" || "$PARAM" == "-file-drop" ]]; then
		FILE_DROP_URL="$2"
		if [ -z "$FILE_DROP_URL" ]; then
			echo "File-drop URL is required after --file-drop option (e.g., http://192.168.31.103:3232/upload)"
			exit 1
		fi
		shift  # shift to remove the URL from the params
	elif [[ "$PARAM" == "--file-drop-url-prefix" || "$PARAM" == "-file-drop-url-prefix" ]]; then
		FILE_DROP_URL_PREFIX="$2"
		if [ -z "$FILE_DROP_URL_PREFIX" ]; then
			echo "URL prefix is required after --file-drop-url-prefix option (e.g., https://gateway.example.com)"
			exit 1
		fi
		shift  # shift to remove the prefix from the params
	elif [[ "$PARAM" == "--enable-h265" || "$PARAM" == "-enable-h265" || "$PARAM" == "--enable-hevc" || "$PARAM" == "-enable-hevc" ]]; then
		ENABLE_H265=1
	elif [[ "$PARAM" == "--nsfw" || "$PARAM" == "-nsfw" ]]; then
		NSFW=1
	elif [[ "$PARAM" =~ ^- ]]; then
		# Unrecognized option starting with - or --
		local SCRIPT_NAME_ERR=$(basename "$0")
		echo "Error: Unrecognized option: $PARAM" >&2
		echo "Use --help to see available options." >&2
		exit 1
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

	# Set return variables
	parse_command_line_ret_media_files=$(serialize_array "${ALL_MEDIA_FILES[@]}")
	parse_command_line_ret_convert_video="$CONVERT_VIDEO"
	parse_command_line_ret_send_to_relay="$SEND_TO_RELAY"
	parse_command_line_ret_disable_hash_check="$DISABLE_HASH_CHECK"
	parse_command_line_ret_max_file_search="$MAX_FILE_SEARCH"
	parse_command_line_ret_pow_diff="$POW_DIFF"
	parse_command_line_ret_append_original_comment="$APPEND_ORIGINAL_COMMENT"
	parse_command_line_ret_use_cookies_ff="$USE_COOKIES_FF"
	parse_command_line_ret_cookies_file="$COOKIES_FILE"
	parse_command_line_ret_display_source="$DISPLAY_SOURCE"
	parse_command_line_ret_password="$PASSWORD"
	parse_command_line_ret_description_candidate="$DESCRIPTION_CANDIDATE"
	parse_command_line_ret_source_candidate="$SOURCE_CANDIDATE"
	parse_command_line_ret_profile_name="$PROFILE_NAME"
	parse_command_line_ret_encoders="$USER_ENCODERS"
	parse_command_line_ret_file_drop_url="$FILE_DROP_URL"
	parse_command_line_ret_file_drop_url_prefix="$FILE_DROP_URL_PREFIX"
	parse_command_line_ret_enable_h265="$ENABLE_H265"
	parse_command_line_ret_nsfw="$NSFW"
	
	# Export PROFILE_NAME as a side effect for early use (before ENV loading)
	export PROFILE_NAME
}

# Function to check all media files against history
# Parameters:
#   $1: ALL_MEDIA_FILES_STR - serialized array of media files/URLs
#   $2: HISTORY_FILE - path to history file
#   $3: DISABLE_HASH_CHECK - 1 to disable, 0 otherwise
# Return variables:
#   check_all_media_history_ret_original_urls - serialized array of normalized URLs
# Note: Dies if any file is found in history
check_all_media_history() {
	local ALL_MEDIA_FILES_STR="$1"
	local HISTORY_FILE="$2"
	local DISABLE_HASH_CHECK="$3"
	
	# Deserialize array
	local ALL_MEDIA_FILES=()
	eval "ALL_MEDIA_FILES=($ALL_MEDIA_FILES_STR)"
	
	local ORIGINAL_URLS=()
	local MEDIA_FILE
	local result
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

	check_all_media_history_ret_original_urls=$(serialize_array "${ORIGINAL_URLS[@]}")
}

# Function to calculate file hashes and check against history
# Parameters:
#   $1: PROCESSED_FILES_STR - serialized array of processed files
#   $2: HISTORY_FILE - path to history file
#   $3: DISABLE_HASH_CHECK - 1 to disable, 0 otherwise
# Return variables:
#   calculate_file_hashes_ret_hashes - serialized array of file hashes
# Note: Dies if any hash is found in history
calculate_file_hashes() {
	local PROCESSED_FILES_STR="$1"
	local HISTORY_FILE="$2"
	local DISABLE_HASH_CHECK="$3"
	
	# Deserialize array
	local PROCESSED_FILES=()
	eval "PROCESSED_FILES=($PROCESSED_FILES_STR)"
	
	local FILE_HASHES=()
	local FILE
	local FILE_HASH
	
	if [ $DISABLE_HASH_CHECK -eq 0 ]; then
		# Process all processed files
		for FILE in "${PROCESSED_FILES[@]}"; do
			if [ -f "$FILE" ]; then
				# Calculate file hash
				FILE_HASH=$(sha256sum "$FILE" | awk '{print $1}')
				# Check if file hash exists in history file
				if check_history "$FILE_HASH" "$HISTORY_FILE" "$DISABLE_HASH_CHECK"; then
					die "File hash already processed: $FILE_HASH"
				fi
				# Add file hash to the array
				FILE_HASHES+=("$FILE_HASH")
	fi
done
	fi
	
	calculate_file_hashes_ret_hashes=$(serialize_array "${FILE_HASHES[@]}")
}

# Function to process all media items (download URLs or use local files)
# Parameters:
#   $1: ALL_MEDIA_FILES_STR - serialized array of media files/URLs
#   $2: HISTORY_FILE - path to history file
#   $3: CONVERT_VIDEO - 1 to convert, 0 otherwise
#   $4: USE_COOKIES_FF - 1 to use Firefox cookies, 0 otherwise
#   $5: COOKIES_FILE - path to cookies file (empty if not provided)
#   $6: APPEND_ORIGINAL_COMMENT - 1 to append, 0 otherwise
#   $7: DISABLE_HASH_CHECK - 1 to disable, 0 otherwise
#   $8: DESCRIPTION_CANDIDATE - description text
#   $9: SOURCE_CANDIDATE - source text
#   $10: GALLERY_DL_PARAMS_STR - serialized array of gallery-dl parameters
#   $11: MAX_FILE_SEARCH - maximum files to search
# Return variables:
#   process_media_items_ret_files - serialized array of processed files
#   process_media_items_ret_captions - serialized array of captions
#   process_media_items_ret_sources - serialized array of sources
#   process_media_items_ret_galleries - serialized array of gallery IDs
process_media_items() {
	local ALL_MEDIA_FILES_STR="$1"
	local HISTORY_FILE="$2"
	local CONVERT_VIDEO="$3"
	local USE_COOKIES_FF="$4"
	local COOKIES_FILE="$5"
	local APPEND_ORIGINAL_COMMENT="$6"
	local DISABLE_HASH_CHECK="$7"
	local DESCRIPTION_CANDIDATE="$8"
	local SOURCE_CANDIDATE="$9"
	local GALLERY_DL_PARAMS_STR="${10}"
	local MAX_FILE_SEARCH="${11}"
	
	# Deserialize arrays
	local ALL_MEDIA_FILES=()
	eval "ALL_MEDIA_FILES=($ALL_MEDIA_FILES_STR)"
	
	local GALLERY_DL_PARAMS=()
	eval "GALLERY_DL_PARAMS=($GALLERY_DL_PARAMS_STR)"
	
	local PROCESSED_FILES=()
	local FILE_CAPTIONS=()
	local FILE_SOURCES=()
	local FILE_GALLERIES=()  # Track which gallery/media item each file belongs to
	local GALLERY_ID=0
	local MEDIA_ITEM
	
	for MEDIA_ITEM in "${ALL_MEDIA_FILES[@]}"; do
		if [[ "$MEDIA_ITEM" =~ ^https?:// ]]; then
			# It's a URL - try to download as video first, then as image
			echo "Processing URL: $MEDIA_ITEM"
		
			# Prepare gallery-dl params as string for passing to function
			local GALLERY_DL_PARAMS_STR_LOCAL
			GALLERY_DL_PARAMS_STR_LOCAL=$(serialize_array "${GALLERY_DL_PARAMS[@]}")
		
			# Try video download first for any URL, unless it looks like a photo URL
			# Initialize return variables (these are global return variables, not local)
			download_video_ret_files=()
			download_video_ret_captions=()
			download_video_ret_source=""
			download_video_ret_success=1
			
			local SKIP_VIDEO_DOWNLOAD=0
			# Check for explicit photo URLs
			# Twitter/X: .../photo/1
			# Facebook: .../share/p/... (photos), .../photos/..., photo.php, .../photo/...
			# Note: Facebook videos use /v/ (videos) or /r/ (reels), not /p/
			# Reddit: i.redd.it (direct images)
			# Common image extensions (jpg, png, etc)
			if [[ "$MEDIA_ITEM" =~ ^https?://(www\.)?(x\.com|twitter\.com)/.*/photo/[0-9]+ ]] || \
			   [[ "$MEDIA_ITEM" =~ ^https?://(www\.)?facebook\.com/share/p/ ]] || \
			   [[ "$MEDIA_ITEM" =~ facebook\.com/.*(photos/|photo\.php|photo/) ]] || \
			   [[ "$MEDIA_ITEM" =~ ^https?://i\.redd\.it/ ]] || \
			   [[ "$MEDIA_ITEM" =~ \.(jpg|jpeg|png|webp|gif)$ ]]; then
				echo "URL looks like a photo, skipping video download attempt"
				SKIP_VIDEO_DOWNLOAD=1
			fi
			
			# Check for mobile shared URLs (bypass yt-dlp as it downloads ads with cookies)
			# Format: https://www.facebook.com/share/********* (multiple chars after /share/)
			# Also: https://www.facebook.com/share/p/********* (multiple chars after /share/p/)
			# But NOT: https://www.facebook.com/share/r/... or /v/... (single letter paths)
			# Pattern: /share/ or /share/p/ followed by 2+ alphanumeric chars (not a single letter + slash)
			if [[ "$MEDIA_ITEM" =~ ^https?://(www\.)?facebook\.com/share/(p/)?[A-Za-z0-9]{2,} ]]; then
				echo "URL is a mobile shared link (multiple chars after /share/ or /share/p/), skipping video download to avoid ads"
				SKIP_VIDEO_DOWNLOAD=1
			fi
			
			if [ $SKIP_VIDEO_DOWNLOAD -eq 0 ]; then
				# Pass empty string for description to prevent per-file replication
				download_video "$MEDIA_ITEM" "$HISTORY_FILE" "$CONVERT_VIDEO" "$USE_COOKIES_FF" "$COOKIES_FILE" "$APPEND_ORIGINAL_COMMENT" "$DISABLE_HASH_CHECK" "" "$SOURCE_CANDIDATE"
			fi
			local VIDEO_DOWNLOAD_RESULT="${download_video_ret_success:-1}"
		
			# If video download succeeded, use its return values
			if [ "$VIDEO_DOWNLOAD_RESULT" -eq 0 ]; then
				# Append downloaded files and captions to parallel arrays
				local idx
				local file
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
				local cleaned_source
				if [ -n "$download_video_ret_source" ]; then
					cleaned_source=$(cleanup_source_url "$download_video_ret_source")
					FILE_SOURCES+=("$cleaned_source")
				fi
				((GALLERY_ID++))
			else
				# Video processing failed - check if it was a download failure or conversion failure
				# If files array is empty or only has the original incompatible file, conversion likely failed
				# Only try gallery-dl if no files were successfully processed (download failed)
				if [ ${#download_video_ret_files[@]} -eq 0 ]; then
					# No files were successfully processed - check if it's a mobile shared URL first
					local MOBILE_SHARED_RESOLVED=0
					local ORIGINAL_MEDIA_ITEM="$MEDIA_ITEM"  # Save original URL
					# Check for mobile shared URLs (multiple chars after /share/ or /share/p/, not single letter paths like /r/, /v/)
					if [[ "$MEDIA_ITEM" =~ ^https?://(www\.)?facebook\.com/share/(p/)?[A-Za-z0-9]{2,} ]]; then
						echo "Video download failed, detected mobile shared URL, attempting to resolve..."
						
						# Initialize return variables
						resolve_mobile_shared_url_ret_photo_url=""
						resolve_mobile_shared_url_ret_success=1
						resolve_mobile_shared_url_ret_error=""
						
						# Call mobile shared URL resolution function
						resolve_mobile_shared_url "$MEDIA_ITEM" "$GALLERY_DL_PARAMS_STR_LOCAL"
						local MOBILE_RESOLVE_RESULT="${resolve_mobile_shared_url_ret_success:-1}"
						
						if [ "$MOBILE_RESOLVE_RESULT" -eq 0 ] && [ -n "$resolve_mobile_shared_url_ret_photo_url" ]; then
							# Successfully resolved to photo URL - check if it has set=a. or set=gm. pattern
							echo "Resolved mobile shared URL to: $resolve_mobile_shared_url_ret_photo_url"
							
							# Check if resolved URL has set=a. or set=gm. pattern (gallery-dl won't work with these)
							if [[ "$resolve_mobile_shared_url_ret_photo_url" =~ set=(a|gm)\.[0-9]+ ]]; then
								echo "Resolved URL has set=a. or set=gm. pattern, using Facebook OG image download with original URL instead of gallery-dl"
								
								# Initialize return variables
								download_facebook_og_ret_files=()
								download_facebook_og_ret_captions=()
								download_facebook_og_ret_source=""
								download_facebook_og_ret_success=1
								download_facebook_og_ret_error=""
								
								# Call Facebook OG image download function with ORIGINAL mobile shared URL
								download_facebook_og_image "$ORIGINAL_MEDIA_ITEM" "$APPEND_ORIGINAL_COMMENT" "" "$SOURCE_CANDIDATE"
								local FACEBOOK_OG_RESULT="${download_facebook_og_ret_success:-1}"
								
								if [ "$FACEBOOK_OG_RESULT" -eq 0 ]; then
									# Success - add files to processed arrays
									if [ ${#download_facebook_og_ret_files[@]} -gt 0 ]; then
										for file in "${download_facebook_og_ret_files[@]}"; do
											PROCESSED_FILES+=("$file")
											# Add the downloaded file to cleanup list
											add_to_cleanup "$file"
										done
										
										# Add captions
										for caption in "${download_facebook_og_ret_captions[@]}"; do
											FILE_CAPTIONS+=("$caption")
										done
										
										# Add gallery IDs (single image, so same gallery ID)
										for file in "${download_facebook_og_ret_files[@]}"; do
											FILE_GALLERIES+=("$GALLERY_ID")
										done
										
										# Update source if provided
										if [ -n "$download_facebook_og_ret_source" ]; then
											cleaned_source=$(cleanup_source_url "$download_facebook_og_ret_source")
											FILE_SOURCES+=("$cleaned_source")
										fi
										
										((GALLERY_ID++))
										echo "Successfully downloaded Facebook image using OG method from resolved mobile shared URL"
										# Skip gallery-dl attempt since we already succeeded - continue to next media item
										continue
									else
										if [ -n "$download_facebook_og_ret_error" ]; then
											echo "Warning: Facebook OG download returned success but no files: $download_facebook_og_ret_error" >&2
										fi
										# Fall through to try gallery-dl
									fi
								else
									# Facebook OG download failed
									if [ -n "$download_facebook_og_ret_error" ]; then
										echo "Warning: Facebook OG download failed: $download_facebook_og_ret_error" >&2
									fi
									# Fall through to try gallery-dl
								fi
							else
								# No set=a./set=gm. pattern, use resolved URL for gallery-dl
								MEDIA_ITEM="$resolve_mobile_shared_url_ret_photo_url"
								MOBILE_SHARED_RESOLVED=1
							fi
						else
							# Mobile shared URL resolution failed
							if [ -n "$resolve_mobile_shared_url_ret_error" ]; then
								echo "Warning: Mobile shared URL resolution failed: $resolve_mobile_shared_url_ret_error" >&2
							fi
						fi
					fi
					
					# Try gallery-dl as fallback (with resolved URL if mobile shared was resolved)
					echo "Video download/processing failed, trying gallery-dl for images"
					# Initialize return variables (these are global return variables, not local)
					download_images_ret_files=()
					download_images_ret_captions=()
					download_images_ret_source=""
					download_images_ret_success=1
					download_images_ret_temp_dir=""
			
					# Call download_images function (Facebook URL handling is done inside)
					# Pass empty string for description to prevent per-file replication
					download_images "$MEDIA_ITEM" "$GALLERY_DL_PARAMS_STR_LOCAL" "$APPEND_ORIGINAL_COMMENT" "" "$SOURCE_CANDIDATE" "$MAX_FILE_SEARCH"
					local IMAGE_DOWNLOAD_RESULT="${download_images_ret_success:-1}"
				
					# Add temp directory to cleanup list if returned
					if [ -n "$download_images_ret_temp_dir" ]; then
						add_to_cleanup "$download_images_ret_temp_dir"
					fi
			
					if [ "$IMAGE_DOWNLOAD_RESULT" -eq 0 ]; then
						# For gallery images, all files from same gallery share the same gallery ID and caption
						# Use the first caption (they should all be the same or similar for gallery downloads)
						local CAPTIONS_STR
						local gallery_caption
						CAPTIONS_STR=$(serialize_array "${download_images_ret_captions[@]}")
						gallery_caption=$(get_first_non_empty_caption "$CAPTIONS_STR")
					
						# Append downloaded files to parallel arrays - all from same gallery
						local current_gallery_id
						local last_idx
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
						# For mobile shared URLs, use the original URL as source, not the resolved URL
						if [ "$MOBILE_SHARED_RESOLVED" -eq 1 ] && [ -n "$ORIGINAL_MEDIA_ITEM" ]; then
							cleaned_source=$(cleanup_source_url "$ORIGINAL_MEDIA_ITEM")
							FILE_SOURCES+=("$cleaned_source")
						elif [ -n "$download_images_ret_source" ]; then
							cleaned_source=$(cleanup_source_url "$download_images_ret_source")
							FILE_SOURCES+=("$cleaned_source")
						fi
						((GALLERY_ID++))
					else
						# Gallery-dl failed - try Facebook OG image fallback if URL matches pattern
						if [[ "$MEDIA_ITEM" =~ ^https?://(www\.)?facebook\.com/(share/p/[^/]+|groups/[^/]+/permalink/[^/]+) ]]; then
							echo "gallery-dl failed, trying Facebook OG image fallback for: $MEDIA_ITEM"
							
							# Initialize return variables
							download_facebook_og_ret_files=()
							download_facebook_og_ret_captions=()
							download_facebook_og_ret_source=""
							download_facebook_og_ret_success=1
							download_facebook_og_ret_error=""
							
							# Call Facebook OG image download function with ORIGINAL mobile shared URL
							download_facebook_og_image "$ORIGINAL_MEDIA_ITEM" "$APPEND_ORIGINAL_COMMENT" "" "$SOURCE_CANDIDATE"
							local FACEBOOK_OG_RESULT="${download_facebook_og_ret_success:-1}"
							
							if [ "$FACEBOOK_OG_RESULT" -eq 0 ]; then
								# Success - add files to processed arrays
								if [ ${#download_facebook_og_ret_files[@]} -gt 0 ]; then
									for file in "${download_facebook_og_ret_files[@]}"; do
										PROCESSED_FILES+=("$file")
										# Add the downloaded file to cleanup list
										add_to_cleanup "$file"
									done
									
									# Add captions
									for caption in "${download_facebook_og_ret_captions[@]}"; do
										FILE_CAPTIONS+=("$caption")
									done
									
									# Add gallery IDs (single image, so same gallery ID)
									for file in "${download_facebook_og_ret_files[@]}"; do
										FILE_GALLERIES+=("$GALLERY_ID")
									done
									
									# Update source if provided
									if [ -n "$download_facebook_og_ret_source" ]; then
										cleaned_source=$(cleanup_source_url "$download_facebook_og_ret_source")
										FILE_SOURCES+=("$cleaned_source")
									fi
									
									((GALLERY_ID++))
									echo "Successfully downloaded Facebook image using OG fallback"
								else
									if [ -n "$download_facebook_og_ret_error" ]; then
										die "$download_facebook_og_ret_error"
									else
										die "Facebook OG fallback returned success but no files"
									fi
								fi
							else
								# Facebook OG fallback also failed
								if [ -n "$download_facebook_og_ret_error" ]; then
									die "$download_facebook_og_ret_error"
								elif [ -n "$download_images_ret_error" ]; then
									die "$download_images_ret_error"
								else
									die "Failed to download from URL: $MEDIA_ITEM (tried yt-dlp, gallery-dl, and Facebook OG fallback)"
								fi
							fi
						else
							# Not a Facebook URL matching the pattern, just die with original error
							if [ -n "$download_images_ret_error" ]; then
								die "$download_images_ret_error"
							else
								die "Failed to download from URL: $MEDIA_ITEM"
							fi
						fi
					fi
				fi
			fi
		else
			# It's a local file
			if [ ! -f "$MEDIA_ITEM" ]; then
				die "File does not exist: $MEDIA_ITEM"
			fi
			PROCESSED_FILES+=("$MEDIA_ITEM")
			
			# Use empty string for description for local files
			local file_caption=$(build_caption "" "" "$APPEND_ORIGINAL_COMMENT")
			FILE_CAPTIONS+=("$file_caption")
			
			FILE_GALLERIES+=("$GALLERY_ID")
			((GALLERY_ID++))
			
			# Add source if provided
			if [ -n "$SOURCE_CANDIDATE" ]; then
				local cleaned_source=$(cleanup_source_url "$SOURCE_CANDIDATE")
				FILE_SOURCES+=("$cleaned_source")
			fi
			echo "Using local file: $MEDIA_ITEM"
		fi
	done

	if [ ${#PROCESSED_FILES[@]} -eq 0 ]; then
		die "No files to upload"
	fi
	
	# Return via return variables
	process_media_items_ret_files=$(serialize_array "${PROCESSED_FILES[@]}")
	process_media_items_ret_captions=$(serialize_array "${FILE_CAPTIONS[@]}")
	process_media_items_ret_sources=$(serialize_array "${FILE_SOURCES[@]}")
	process_media_items_ret_galleries=$(serialize_array "${FILE_GALLERIES[@]}")
}

# Function to upload files and publish Nostr event
# Parameters:
#   $1: PROCESSED_FILES_STR - serialized array of processed files
#   $2: FILE_CAPTIONS_STR - serialized array of captions
#   $3: FILE_SOURCES_STR - serialized array of sources
#   $4: FILE_GALLERIES_STR - serialized array of gallery IDs
#   $5: BLOSSOMS_LIST_STR - serialized array of blossom servers
#   $6: RELAYS_LIST - string of relay servers
#   $7: KEY_DECRYPTED - decrypted private key
#   $8: POW_DIFF - proof of work difficulty
#   $9: DISPLAY_SOURCE - 1 to display, 0 otherwise
#   $10: SEND_TO_RELAY - 1 to send, 0 otherwise
#   $11: DESCRIPTION - global description to append at the end
#   $12: FILE_DROP_URL - file-drop server URL (empty if not set, will fall back to blossom)
#   $13: FILE_DROP_URL_PREFIX - URL prefix to replace https://dweb.link/ (empty if not set)
# Returns: Exit code (0=success, dies on failure)
upload_and_publish_event() {
	local PROCESSED_FILES_STR="$1"
	local FILE_CAPTIONS_STR="$2"
	local FILE_SOURCES_STR="$3"
	local FILE_GALLERIES_STR="$4"
	local BLOSSOMS_LIST_STR="$5"
	local RELAYS_LIST="$6"
	local KEY_DECRYPTED="$7"
	local POW_DIFF="$8"
	local DISPLAY_SOURCE="$9"
	local SEND_TO_RELAY="${10}"
	local DESCRIPTION="${11}"
	local FILE_DROP_URL="${12}"
	local FILE_DROP_URL_PREFIX="${13}"
	
	# Deserialize arrays
	local PROCESSED_FILES=()
	local FILE_CAPTIONS=()
	local FILE_SOURCES=()
	local FILE_GALLERIES=()
	local BLOSSOMS_LIST=()
	eval "PROCESSED_FILES=($PROCESSED_FILES_STR)"
	eval "FILE_CAPTIONS=($FILE_CAPTIONS_STR)"
	eval "FILE_SOURCES=($FILE_SOURCES_STR)"
	eval "FILE_GALLERIES=($FILE_GALLERIES_STR)"
	eval "BLOSSOMS_LIST=($BLOSSOMS_LIST_STR)"

	# Filter out empty entries from BLOSSOMS_LIST
	local FILTERED_BLOSSOMS=()
	for BLOSSOM_ENTRY in "${BLOSSOMS_LIST[@]}"; do
		# Remove quotes if present and check if non-empty
		BLOSSOM_ENTRY=$(echo "$BLOSSOM_ENTRY" | sed "s/^['\"]//;s/['\"]$//")
		if [ -n "$BLOSSOM_ENTRY" ]; then
			FILTERED_BLOSSOMS+=("$BLOSSOM_ENTRY")
		fi
	done
	BLOSSOMS_LIST=("${FILTERED_BLOSSOMS[@]}")

if [ ${#PROCESSED_FILES[@]} -eq 0 ]; then
	die "No files to upload"
fi

	local UPLOAD_URLS=()
	local RESULT=0
	local upload_success=0
	local TRIES
	local BLOSSOM
	local FILE
	local upload_url
	local CONTENT
	local NAK_CMD
	local RELAY
	
	# Try file-drop first if configured
	if [ -n "$FILE_DROP_URL" ]; then
		echo "Trying file-drop server: $FILE_DROP_URL"
		UPLOAD_URLS=()
		upload_success=1
		
		for FILE in "${PROCESSED_FILES[@]}"; do
			upload_url=$(upload_file_to_filedrop "$FILE" "$FILE_DROP_URL" "$FILE_DROP_URL_PREFIX")
			if [ $? -ne 0 ]; then
				echo "File-drop upload failed for $FILE, will fall back to blossom servers" >&2
				upload_success=0
				break
			fi
			UPLOAD_URLS+=("$upload_url")
		done
		
		# If file-drop succeeded for all files, proceed with publishing
		if [ $upload_success -eq 1 ]; then
			echo "Successfully uploaded all files to file-drop server"
		else
			echo "File-drop upload failed, falling back to blossom servers" >&2
			UPLOAD_URLS=()
		fi
	fi
	
	# If file-drop not configured or failed, use blossom servers
	if [ ${#UPLOAD_URLS[@]} -eq 0 ]; then
		# Check if we have any valid blossom servers
		if [ ${#BLOSSOMS_LIST[@]} -eq 0 ]; then
			if [ -n "$FILE_DROP_URL" ]; then
				die "File-drop upload failed and no valid blossom servers configured. Please check your BLOSSOMS configuration."
			else
				die "No valid blossom servers configured. Please check your BLOSSOMS configuration."
			fi
		fi
		
		for TRIES in "${!BLOSSOMS_LIST[@]}"; do
			BLOSSOM="${BLOSSOMS_LIST[$TRIES]}"
			# Skip empty blossom URLs
			if [ -z "$BLOSSOM" ]; then
				echo "Skipping empty blossom server entry" >&2
				continue
			fi
			echo "Using blossom: $BLOSSOM, try: $((TRIES+1))"
		
			UPLOAD_URLS=()
			upload_success=1
			
			for FILE in "${PROCESSED_FILES[@]}"; do
				upload_url=$(upload_file_to_blossom "$FILE" "$BLOSSOM" "$KEY_DECRYPTED")
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
			
			# Successfully uploaded to this blossom server, break out of loop
			break
		done
	fi
	
	# Check if we successfully uploaded all files
	if [ ${#UPLOAD_URLS[@]} -ne ${#PROCESSED_FILES[@]} ]; then
		die "Failed to upload all files (uploaded ${#UPLOAD_URLS[@]} of ${#PROCESSED_FILES[@]})"
	fi

	# Build content for kind 1 event: interleaved URL -> caption -> URL -> caption, then sources at bottom
	# For gallery images: all URLs first, then caption for the gallery
	# Formatting: empty line after images before caption, 2 empty lines after caption before next URL
		local UPLOAD_URLS_STR
		local FILE_CAPTIONS_STR_LOCAL
		local FILE_GALLERIES_STR_LOCAL
		local FILE_SOURCES_STR_LOCAL
		UPLOAD_URLS_STR=$(serialize_array "${UPLOAD_URLS[@]}")
		FILE_CAPTIONS_STR_LOCAL=$(serialize_array "${FILE_CAPTIONS[@]}")
		FILE_GALLERIES_STR_LOCAL=$(serialize_array "${FILE_GALLERIES[@]}")
		FILE_SOURCES_STR_LOCAL=$(serialize_array "${FILE_SOURCES[@]}")
		CONTENT=$(build_event_content "$UPLOAD_URLS_STR" "$FILE_CAPTIONS_STR_LOCAL" "$FILE_GALLERIES_STR_LOCAL" "$FILE_SOURCES_STR_LOCAL" "$DISPLAY_SOURCE" "$DESCRIPTION")
	
	# Print content for debugging before creating event
	echo "=== Event Content (Debug) ==="
	echo "$CONTENT"
	echo "=== End Event Content ==="

	# Check if NSFW tag should be added
	# Check if NSFW is enabled via command line or environment variable
	local ADD_NSFW_TAG=0
	if [ "${NSFW:-0}" -eq 1 ]; then
		ADD_NSFW_TAG=1
		echo "NSFW flag is enabled"
	fi
	
	# Check if content contains #NSFW or #nsfw hashtag
	if [ $ADD_NSFW_TAG -eq 0 ] && [ -n "$CONTENT" ]; then
		if echo "$CONTENT" | grep -qiE '#nsfw\b'; then
			ADD_NSFW_TAG=1
			echo "NSFW hashtag detected in content"
		fi
	fi

	# Create kind 1 event with nak
	echo "Creating kind 1 event with content length: ${#CONTENT}"
	
		NAK_CMD=("nak" "event" "--kind" "1" "-sec" "$KEY_DECRYPTED" "--pow" "$POW_DIFF")
	if [ "$SEND_TO_RELAY" -eq 1 ]; then
			NAK_CMD+=("--auth" "-sec" "$KEY_DECRYPTED")
			for RELAY in $RELAYS_LIST; do
			NAK_CMD+=("$RELAY")
		done
	fi
	
	if [ -n "$CONTENT" ]; then
		NAK_CMD+=("--content" "$(echo -e "$CONTENT")")
	else
		NAK_CMD+=("--content" "")
	fi
	
	# Add content-warning tag if NSFW is enabled or detected
	if [ $ADD_NSFW_TAG -eq 1 ]; then
		NAK_CMD+=("-t" "content-warning=nsfw")
		echo "Adding content-warning tag for NSFW content"
	fi
	
	# Extract hashtags from content and add them as tags
	# Pattern: # followed by alphanumeric characters and underscores
	if [ -n "$CONTENT" ]; then
		local HASHTAGS=()
		local SEEN_TAGS=()  # Track lowercase versions for case-insensitive deduplication
		
		# Extract all hashtags from content
		while IFS= read -r hashtag; do
			# Remove the leading # 
			local tag_value="${hashtag#\#}"
			# Only process non-empty tags
			if [ -n "$tag_value" ]; then
				# Check if we already have this tag (case-insensitive)
				local tag_lower="${tag_value,,}"
				local found=0
				for seen_tag in "${SEEN_TAGS[@]}"; do
					if [ "$seen_tag" = "$tag_lower" ]; then
						found=1
						break
					fi
				done
				if [ $found -eq 0 ]; then
					HASHTAGS+=("$tag_value")
					SEEN_TAGS+=("$tag_lower")
				fi
			fi
		done < <(echo "$CONTENT" | grep -oE '#[A-Za-z0-9_]+')
		
		# Add hashtags as tags to nak command
		if [ ${#HASHTAGS[@]} -gt 0 ]; then
			echo "Found ${#HASHTAGS[@]} unique hashtag(s) in content"
			for hashtag in "${HASHTAGS[@]}"; do
				NAK_CMD+=("-t" "t=$hashtag")
				echo "Adding hashtag tag: t=$hashtag"
			done
		fi
	fi
	
	echo "${NAK_CMD[@]}"
	"${NAK_CMD[@]}"
	RESULT=$?
	
	if [ $RESULT -eq 0 ]; then
		echo "Successfully published kind 1 event"
		return 0
	else
		echo "Failed to publish kind 1 event" >&2
		die "Failed to publish kind 1 event"
	fi
}

# Function to update history file after successful publish
# Parameters:
#   $1: HISTORY_FILE - path to history file
#   $2: FILE_HASHES_STR - serialized array of file hashes
#   $3: ORIGINAL_URLS_STR - serialized array of normalized URLs
#   $4: ALL_MEDIA_FILES_STR - serialized array of all media files
#   $5: SEND_TO_RELAY - 1 if sent to relay, 0 otherwise
#   $6: DISABLE_HASH_CHECK - 1 to disable, 0 otherwise
# Returns: Exit code (0=written, 1=skipped)
update_history_file() {
	local HISTORY_FILE="$1"
	local FILE_HASHES_STR="$2"
	local ORIGINAL_URLS_STR="$3"
	local ALL_MEDIA_FILES_STR="$4"
	local SEND_TO_RELAY="$5"
	local DISABLE_HASH_CHECK="$6"
	
	# Only update history if sent to relays and hash check is enabled
	if [ "$SEND_TO_RELAY" -ne 1 ] || [ "$DISABLE_HASH_CHECK" -ne 0 ]; then
		return 1
	fi
	
	# Deserialize arrays
	local FILE_HASHES=()
	local ORIGINAL_URLS=()
	local ALL_MEDIA_FILES=()
	if [ -n "$FILE_HASHES_STR" ]; then
		eval "FILE_HASHES=($FILE_HASHES_STR)"
	fi
	if [ -n "$ORIGINAL_URLS_STR" ]; then
		eval "ORIGINAL_URLS=($ORIGINAL_URLS_STR)"
	fi
	eval "ALL_MEDIA_FILES=($ALL_MEDIA_FILES_STR)"
	
	# Write hashes
	if [ ${#FILE_HASHES[@]} -gt 0 ]; then
		local FILE_HASHES_STR_LOCAL
		FILE_HASHES_STR_LOCAL=$(serialize_array "${FILE_HASHES[@]}")
		write_to_history "$HISTORY_FILE" "$FILE_HASHES_STR_LOCAL"
	fi
	
	# Write URLs
	if [ ${#ORIGINAL_URLS[@]} -gt 0 ]; then
		local ORIGINAL_URLS_STR_LOCAL
		ORIGINAL_URLS_STR_LOCAL=$(serialize_array "${ORIGINAL_URLS[@]}")
		write_to_history "$HISTORY_FILE" "$ORIGINAL_URLS_STR_LOCAL"
	fi
	
	# Collect and write local files
	local LOCAL_FILES=()
	local MEDIA_FILE
	for MEDIA_FILE in "${ALL_MEDIA_FILES[@]}"; do
		if [ -f "$MEDIA_FILE" ]; then
			# It's a local file
			LOCAL_FILES+=("$MEDIA_FILE")
		fi
	done
	
	if [ ${#LOCAL_FILES[@]} -gt 0 ]; then
		local LOCAL_FILES_STR
		LOCAL_FILES_STR=$(serialize_array "${LOCAL_FILES[@]}")
		write_to_history "$HISTORY_FILE" "$LOCAL_FILES_STR"
	fi
	
	return 0
}

# Main function containing all script logic
# Parameters:
#   $@ - command-line arguments
main() {
	# All variables declared as local
	
	# ========================================================================
	# READ EXPORTED VARIABLES (read-only)
	# ========================================================================
	local DISPLAY_SOURCE="${DISPLAY_SOURCE:-0}"
	local POW_DIFF="${POW_DIFF:-20}"
	local APPEND_ORIGINAL_COMMENT="${APPEND_ORIGINAL_COMMENT:-1}"
	local USE_COOKIES_FF="${USE_COOKIES_FF:-0}"
	local NSEC_KEY="${NSEC_KEY:-}"
	local NCRYPT_KEY="${NCRYPT_KEY:-}"
	local KEY="${KEY:-}"
	local PASSWORD="${PASSWORD:-}"
	local EXTRA_RELAYS=("${EXTRA_RELAYS[@]}")
	local EXTRA_BLOSSOMS=("${EXTRA_BLOSSOMS[@]}")
	
	# ========================================================================
	# SCRIPT METADATA
	# ========================================================================
	local HISTORY_FILE
	get_script_metadata "$PROFILE_NAME"
	HISTORY_FILE="$get_script_metadata_ret_history_file"
	
	# ========================================================================
	# VALIDATION
	# ========================================================================
	validate_configuration "$HISTORY_FILE" "$NSEC_KEY" "$KEY" "$NCRYPT_KEY"
	
	# ========================================================================
	# PROCESS RELAYS AND BLOSSOMS
	# ========================================================================
	local EXTRA_RELAYS_STR
	local EXTRA_BLOSSOMS_STR
	EXTRA_RELAYS_STR=$(serialize_array "${EXTRA_RELAYS[@]}")
	EXTRA_BLOSSOMS_STR=$(serialize_array "${EXTRA_BLOSSOMS[@]}")
	
	local RELAYS_LIST
	local BLOSSOMS_LIST_STR
	process_relays_and_blossoms "$EXTRA_RELAYS_STR" "$EXTRA_BLOSSOMS_STR"
	RELAYS_LIST="$process_relays_and_blossoms_ret_relays_list"
	BLOSSOMS_LIST_STR="$process_relays_and_blossoms_ret_blossoms_list"
	
	# ========================================================================
	# READ EXPORTED VARIABLES (merged from env file and command-line)
	# ========================================================================
	local ALL_MEDIA_FILES_STR="$PARSED_MEDIA_FILES"
	local CONVERT_VIDEO="${CONVERT_VIDEO:-1}"
	local SEND_TO_RELAY="${SEND_TO_RELAY:-1}"
	local DISABLE_HASH_CHECK="${DISABLE_HASH_CHECK:-0}"
	local MAX_FILE_SEARCH="${MAX_FILE_SEARCH:-10}"
	local POW_DIFF="${POW_DIFF:-20}"
	local APPEND_ORIGINAL_COMMENT="${APPEND_ORIGINAL_COMMENT:-1}"
	local USE_COOKIES_FF="${USE_COOKIES_FF:-0}"
	local DISPLAY_SOURCE="${DISPLAY_SOURCE:-0}"
	local PASSWORD="${PASSWORD:-}"
	local DESCRIPTION_CANDIDATE="$PARSED_DESCRIPTION_CANDIDATE"
	local SOURCE_CANDIDATE="$PARSED_SOURCE_CANDIDATE"
	
	# If not sending to relay (e.g. testing), disable hash check so we don't stop if already exists
	if [ "$SEND_TO_RELAY" -eq 0 ]; then
		DISABLE_HASH_CHECK=1
	fi
	
	# ========================================================================
	# CHECK MEDIA HISTORY
	# ========================================================================
	local ORIGINAL_URLS_STR
	check_all_media_history "$ALL_MEDIA_FILES_STR" "$HISTORY_FILE" "$DISABLE_HASH_CHECK"
	ORIGINAL_URLS_STR="$check_all_media_history_ret_original_urls"
	
	# ========================================================================
	# DECRYPT KEY
	# ========================================================================
	local KEY_DECRYPTED
	KEY_DECRYPTED=$(decrypt_key "$NSEC_KEY" "$NCRYPT_KEY" "$KEY" "$PASSWORD")
	if [ $? -ne 0 ]; then
		die "Decryption failed, key is empty"
	fi
	
	# ========================================================================
	# PREPARE GALLERY-DL PARAMS
	# ========================================================================
	local GALLERY_DL_PARAMS_STR
	# COOKIES_FILE is already set in the merge section above
	prepare_gallery_dl_params "$USE_COOKIES_FF" "$COOKIES_FILE"
	GALLERY_DL_PARAMS_STR="$prepare_gallery_dl_params_ret_params"
	
	# ========================================================================
	# PROCESS MEDIA ITEMS
	# ========================================================================
	local PROCESSED_FILES_STR
	local FILE_CAPTIONS_STR
	local FILE_SOURCES_STR
	local FILE_GALLERIES_STR
	process_media_items "$ALL_MEDIA_FILES_STR" "$HISTORY_FILE" "$CONVERT_VIDEO" \
		"$USE_COOKIES_FF" "$COOKIES_FILE" "$APPEND_ORIGINAL_COMMENT" "$DISABLE_HASH_CHECK" \
		"$DESCRIPTION_CANDIDATE" "$SOURCE_CANDIDATE" "$GALLERY_DL_PARAMS_STR" \
		"$MAX_FILE_SEARCH"
	PROCESSED_FILES_STR="$process_media_items_ret_files"
	FILE_CAPTIONS_STR="$process_media_items_ret_captions"
	FILE_SOURCES_STR="$process_media_items_ret_sources"
	FILE_GALLERIES_STR="$process_media_items_ret_galleries"
	
	# ========================================================================
	# CALCULATE FILE HASHES
	# ========================================================================
	local FILE_HASHES_STR
	calculate_file_hashes "$PROCESSED_FILES_STR" "$HISTORY_FILE" "$DISABLE_HASH_CHECK"
	FILE_HASHES_STR="$calculate_file_hashes_ret_hashes"
	
	# ========================================================================
	# UPLOAD AND PUBLISH EVENT
	# ========================================================================
	local FILE_DROP_URL="${FILE_DROP_URL:-}"
	local FILE_DROP_URL_PREFIX="${FILE_DROP_URL_PREFIX:-}"
	upload_and_publish_event "$PROCESSED_FILES_STR" "$FILE_CAPTIONS_STR" "$FILE_SOURCES_STR" \
		"$FILE_GALLERIES_STR" "$BLOSSOMS_LIST_STR" "$RELAYS_LIST" "$KEY_DECRYPTED" \
		"$POW_DIFF" "$DISPLAY_SOURCE" "$SEND_TO_RELAY" "$DESCRIPTION_CANDIDATE" "$FILE_DROP_URL" "$FILE_DROP_URL_PREFIX"
	
	# ========================================================================
	# UPDATE HISTORY FILE
	# ========================================================================
	update_history_file "$HISTORY_FILE" "$FILE_HASHES_STR" "$ORIGINAL_URLS_STR" \
		"$ALL_MEDIA_FILES_STR" "$SEND_TO_RELAY" "$DISABLE_HASH_CHECK"

	# Cleanup is called automatically via trap
}

# ============================================================================
# SCRIPT BODY
# ============================================================================

# Check if help option is provided (before loading env)
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

# Set PROFILE_NAME to script name (without extension) by default
# It will be overridden if -p/--profile option is provided
SCRIPT_NAME=$(basename "$0")
PROFILE_NAME="${SCRIPT_NAME%.*}"

# Parse command-line arguments early to extract PROFILE_NAME before loading ENV
# Store all parsed results for use in main()
parse_command_line "$@"
PARSED_PROFILE_NAME="$parse_command_line_ret_profile_name"
PARSED_MEDIA_FILES="$parse_command_line_ret_media_files"
PARSED_CONVERT_VIDEO="$parse_command_line_ret_convert_video"
PARSED_SEND_TO_RELAY="$parse_command_line_ret_send_to_relay"
PARSED_DISABLE_HASH_CHECK="$parse_command_line_ret_disable_hash_check"
PARSED_MAX_FILE_SEARCH="$parse_command_line_ret_max_file_search"
PARSED_POW_DIFF="$parse_command_line_ret_pow_diff"
PARSED_APPEND_ORIGINAL_COMMENT="$parse_command_line_ret_append_original_comment"
PARSED_USE_COOKIES_FF="$parse_command_line_ret_use_cookies_ff"
PARSED_COOKIES_FILE="$parse_command_line_ret_cookies_file"
PARSED_DISPLAY_SOURCE="$parse_command_line_ret_display_source"
PARSED_PASSWORD="$parse_command_line_ret_password"
PARSED_DESCRIPTION_CANDIDATE="$parse_command_line_ret_description_candidate"
PARSED_SOURCE_CANDIDATE="$parse_command_line_ret_source_candidate"
PARSED_ENCODERS="$parse_command_line_ret_encoders"
PARSED_FILE_DROP_URL="$parse_command_line_ret_file_drop_url"
PARSED_FILE_DROP_URL_PREFIX="$parse_command_line_ret_file_drop_url_prefix"
PARSED_ENABLE_H265="$parse_command_line_ret_enable_h265"
PARSED_NSFW="$parse_command_line_ret_nsfw"

# Use extracted PROFILE_NAME to load config
if [ -n "$PARSED_PROFILE_NAME" ]; then
	PROFILE_NAME="$PARSED_PROFILE_NAME"
fi

# ========================================================================
# LOAD ENVIRONMENT VARIABLES FROM PROFILE FILE
# ========================================================================
ENV_FILE="$HOME/.nostr/${PROFILE_NAME}"
if [[ -f "$ENV_FILE" ]]; then
	# shellcheck source=/dev/null
	source "$ENV_FILE"
fi

# ========================================================================
# MERGE ENVIRONMENT VARIABLES WITH PARSED PARAMETERS
# Command-line parameters take precedence over environment variables
# ========================================================================

# Support NO_RELAY environment variable as an alternative to SEND_TO_RELAY=0
if [[ "${NO_RELAY:-0}" == "1" ]] || [[ "${NO_RELAY:-0}" == "true" ]] || [[ "${NO_RELAY:-0}" == "yes" ]]; then
	SEND_TO_RELAY=0
fi

# Support DISABLE_RELAY environment variable as an alternative to SEND_TO_RELAY=0
if [[ "${DISABLE_RELAY:-0}" == "1" ]] || [[ "${DISABLE_RELAY:-0}" == "true" ]] || [[ "${DISABLE_RELAY:-0}" == "yes" ]]; then
	SEND_TO_RELAY=0
fi

# Merge ENCODERS: Command-line takes precedence over environment variable
if [ -n "$PARSED_ENCODERS" ]; then
	ENCODERS="$PARSED_ENCODERS"
elif [ -n "${ENCODERS:-}" ]; then
	# Use environment variable if set
	ENCODERS="$ENCODERS"
else
	# No encoders specified, will use automatic detection
	ENCODERS=""
fi

# Merge FILE_DROP_URL: Command-line takes precedence over environment variable
if [ -n "$PARSED_FILE_DROP_URL" ]; then
	FILE_DROP_URL="$PARSED_FILE_DROP_URL"
elif [ -n "${FILE_DROP_URL:-}" ]; then
	# Use environment variable if set
	FILE_DROP_URL="$FILE_DROP_URL"
else
	# No file-drop URL specified
	FILE_DROP_URL=""
fi

# Merge FILE_DROP_URL_PREFIX: Command-line takes precedence over environment variable
if [ -n "$PARSED_FILE_DROP_URL_PREFIX" ]; then
	FILE_DROP_URL_PREFIX="$PARSED_FILE_DROP_URL_PREFIX"
elif [ -n "${FILE_DROP_URL_PREFIX:-}" ]; then
	# Use environment variable if set
	FILE_DROP_URL_PREFIX="$FILE_DROP_URL_PREFIX"
else
	# No file-drop URL prefix specified
	FILE_DROP_URL_PREFIX=""
fi

# Merge ENABLE_H265: Command-line takes precedence over environment variable
# Default is 0 (disabled, only H264)
if [ "$PARSED_ENABLE_H265" -eq 1 ]; then
	ENABLE_H265=1
elif [ -n "${ENABLE_H265:-}" ]; then
	# Use environment variable if set (convert to 0/1)
	if [[ "${ENABLE_H265}" == "1" ]] || [[ "${ENABLE_H265}" == "true" ]] || [[ "${ENABLE_H265}" == "yes" ]]; then
		ENABLE_H265=1
	else
		ENABLE_H265=0
	fi
else
	# Default: disabled (only H264)
	ENABLE_H265=0
fi

# Merge: Use parsed command-line value if it was explicitly set (differs from default),
# otherwise use environment variable from profile file

# CONVERT_VIDEO: default is 1, if parsed is 0, it was explicitly set (--noconvert)
if [ "$PARSED_CONVERT_VIDEO" -eq 0 ]; then
	CONVERT_VIDEO=0
else
	CONVERT_VIDEO="${CONVERT_VIDEO:-$PARSED_CONVERT_VIDEO}"
fi

# SEND_TO_RELAY: default is 1, if parsed is 0, it was explicitly set (--norelay)
if [ "$PARSED_SEND_TO_RELAY" -eq 0 ]; then
	SEND_TO_RELAY=0
else
	SEND_TO_RELAY="${SEND_TO_RELAY:-$PARSED_SEND_TO_RELAY}"
fi

# DISABLE_HASH_CHECK: default is 0, if parsed is 1, it was explicitly set (--nocheck)
if [ "$PARSED_DISABLE_HASH_CHECK" -eq 1 ]; then
	DISABLE_HASH_CHECK=1
else
	DISABLE_HASH_CHECK="${DISABLE_HASH_CHECK:-$PARSED_DISABLE_HASH_CHECK}"
fi

# POW_DIFF: default is 20, if parsed is 0, it was explicitly set (--nopow)
# Otherwise use env if set, else use parsed value
if [ "$PARSED_POW_DIFF" -eq 0 ] && [ "${POW_DIFF:-20}" -ne 0 ]; then
	# --nopow was used, use 0
	POW_DIFF=0
else
	POW_DIFF="${POW_DIFF:-$PARSED_POW_DIFF}"
fi

# APPEND_ORIGINAL_COMMENT: default is 1, if parsed is 0, it was explicitly set (--nocomment)
if [ "$PARSED_APPEND_ORIGINAL_COMMENT" -eq 0 ]; then
	APPEND_ORIGINAL_COMMENT=0
else
	APPEND_ORIGINAL_COMMENT="${APPEND_ORIGINAL_COMMENT:-$PARSED_APPEND_ORIGINAL_COMMENT}"
fi

# COOKIES_FILE: command line takes precedence, then env var
# If COOKIES_FILE is set (from env or command line), it takes precedence over USE_COOKIES_FF
COOKIES_FILE="${PARSED_COOKIES_FILE:-${COOKIES_FILE:-}}"
if [ -n "$COOKIES_FILE" ]; then
	# Cookies file is set, disable USE_COOKIES_FF and ignore --firefox
	USE_COOKIES_FF=0
	if [ "$PARSED_USE_COOKIES_FF" -eq 1 ]; then
		echo "Ignoring --firefox option because COOKIES_FILE is set" >&2
	fi
else
	# No cookies file, use USE_COOKIES_FF logic
	# USE_COOKIES_FF: default is 0, if parsed is 1, it was explicitly set (--firefox)
	if [ "$PARSED_USE_COOKIES_FF" -eq 1 ]; then
		USE_COOKIES_FF=1
	else
		USE_COOKIES_FF="${USE_COOKIES_FF:-$PARSED_USE_COOKIES_FF}"
	fi
fi

# DISPLAY_SOURCE: default is 0, if parsed is 1, it was explicitly set (--source)
if [ "$PARSED_DISPLAY_SOURCE" -eq 1 ]; then
	DISPLAY_SOURCE=1
else
	DISPLAY_SOURCE="${DISPLAY_SOURCE:-$PARSED_DISPLAY_SOURCE}"
fi

# PASSWORD: use parsed if set, otherwise use env
PASSWORD="${PARSED_PASSWORD:-${PASSWORD:-}}"

# MAX_FILE_SEARCH: use parsed if set, otherwise use env
MAX_FILE_SEARCH="${PARSED_MAX_FILE_SEARCH:-${MAX_FILE_SEARCH:-10}}"

# Merge NSFW: Command-line takes precedence over environment variable
# Default is 0 (not NSFW)
if [ "$PARSED_NSFW" -eq 1 ]; then
	NSFW=1
elif [ -n "${NSFW:-}" ]; then
	# Use environment variable if set (convert to 0/1)
	if [[ "${NSFW}" == "1" ]] || [[ "${NSFW}" == "true" ]] || [[ "${NSFW}" == "yes" ]]; then
		NSFW=1
	else
		NSFW=0
	fi
else
	# Default: not NSFW
	NSFW=0
fi

# ========================================================================
# EXPORT MERGED VARIABLES FOR main() TO READ
# ========================================================================
export DISPLAY_SOURCE
export POW_DIFF
export APPEND_ORIGINAL_COMMENT
export USE_COOKIES_FF
export SEND_TO_RELAY
export CONVERT_VIDEO
export DISABLE_HASH_CHECK
export MAX_FILE_SEARCH
export PASSWORD
export NSEC_KEY
export NCRYPT_KEY
export KEY
export EXTRA_RELAYS
export EXTRA_BLOSSOMS
export PROFILE_NAME
export FILE_DROP_URL
export FILE_DROP_URL_PREFIX
export ENABLE_H265
export NSFW

# Export parsed command-line results for main() to use
export PARSED_MEDIA_FILES
export PARSED_CONVERT_VIDEO
export PARSED_SEND_TO_RELAY
export PARSED_DISABLE_HASH_CHECK
export PARSED_MAX_FILE_SEARCH
export PARSED_POW_DIFF
export PARSED_APPEND_ORIGINAL_COMMENT
export PARSED_USE_COOKIES_FF
export PARSED_DISPLAY_SOURCE
export PARSED_PASSWORD
export PARSED_DESCRIPTION_CANDIDATE
export PARSED_SOURCE_CANDIDATE

# Call main function (no arguments needed, already parsed)
main

