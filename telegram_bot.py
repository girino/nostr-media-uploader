#!/usr/bin/env python3
"""
Telegram bot that listens for links from the owner and calls nostr_media_uploader.sh
"""

import os
import re
import sys
import subprocess
import asyncio
import logging
import yaml
import argparse
import tempfile
import signal
import time
try:
    import psutil
    PSUTIL_AVAILABLE = True
except ImportError:
    PSUTIL_AVAILABLE = False
from pathlib import Path
from collections import defaultdict
from typing import Dict, List, Optional
from urllib.parse import urlparse
from telegram import Update
from telegram.ext import Application, MessageHandler, filters, ContextTypes
from telegram.error import TimedOut, NetworkError


# Configure logging
logging.basicConfig(
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    level=logging.INFO
)
logger = logging.getLogger(__name__)

# Configuration
CONFIG_FILE = os.getenv('TELEGRAM_BOT_CONFIG', 'telegram_bot.yaml')

# Detect Cygwin environment
IS_CYGWIN = sys.platform == 'cygwin'

# Media group handling: store pending media groups
# Format: {media_group_id: {'messages': [messages], 'task': asyncio.Task, 'processed': bool}}
pending_media_groups: Dict[str, Dict] = {}

# Split media group handling: track groups that might be split across multiple media_group_ids
# Format: {(chat_id, caption_hash): {'groups': [{'media_group_id': str, 'messages': [messages]}], 'task': asyncio.Task, 'processed': bool, 'channel_config': dict}}
pending_split_groups: Dict[tuple, Dict] = {}

# Timeout for waiting for more messages in a media group (in seconds)
MEDIA_GROUP_TIMEOUT = 2.0

# Timeout for waiting for additional split groups with the same caption (in seconds)
SPLIT_GROUP_TIMEOUT = 3.0

# Track running processes for cleanup on shutdown
# Format: {pid: {'process': subprocess.Process, 'cmd': list}}
running_processes: Dict[int, Dict] = {}

# Track running processes for cleanup on shutdown
# Format: {pid: {'process': subprocess.Process, 'cmd': list, 'started': timestamp}}
running_processes: Dict[int, Dict] = {}

# URL regex pattern to match http/https links
URL_PATTERN = re.compile(
    r'http[s]?://(?:[a-zA-Z]|[0-9]|[$-_@.&+]|[!*\\(\\),]|(?:%[0-9a-fA-F][0-9a-fA-F]))+'
)


def load_config(config_path, use_firefox=True, cookies_file=None):
    """Load configuration from YAML file.
    
    Expected structure:
    bot_token: YOUR_BOT_TOKEN
    owner_id: YOUR_USER_ID
    script_path: ./nostr_media_uploader.sh
    cookies_file: /path/to/cookies.txt  # Optional: path to cookies file (Mozilla format)
    channels:
      channel1:
        chat_id: -1001234567890
        profile_name: tarado
      channel2:
        chat_id: @channelname
        profile_name: another_profile
    """
    if not os.path.exists(config_path):
        logger.error(f"Configuration file not found: {config_path}")
        raise FileNotFoundError(f"Configuration file not found: {config_path}")
    
    with open(config_path, 'r', encoding='utf-8') as f:
        config_data = yaml.safe_load(f)
    
    if not config_data:
        raise ValueError("Configuration file is empty or invalid")
    
    # Validate required global settings
    if 'bot_token' not in config_data:
        raise ValueError("bot_token is required in configuration")
    if 'owner_id' not in config_data:
        raise ValueError("owner_id is required in configuration")
    
    # Get cookies_file from config if not provided via command line
    # Command line takes precedence
    config_cookies_file = config_data.get('cookies_file')
    if cookies_file is None:
        cookies_file = config_cookies_file
    
    # Validate cookies file if provided
    if cookies_file and not os.path.exists(cookies_file):
        logger.warning(f"Cookies file specified but not found: {cookies_file}")
        # Don't raise error, just log warning - user might fix it later
    
    # Get script timeout (default: 6 minutes = 360 seconds)
    script_timeout = config_data.get('script_timeout', 360)
    # Convert to int if it's a number
    if isinstance(script_timeout, (int, float)):
        script_timeout = int(script_timeout)
    elif isinstance(script_timeout, str):
        # Support format like "6m" or "360s"
        script_timeout_str = script_timeout.lower().strip()
        if script_timeout_str.endswith('m'):
            script_timeout = int(float(script_timeout_str[:-1]) * 60)
        elif script_timeout_str.endswith('s'):
            script_timeout = int(float(script_timeout_str[:-1]))
        else:
            script_timeout = int(float(script_timeout_str))
    else:
        script_timeout = 360  # Default fallback
    
    return {
        'bot_token': config_data.get('bot_token'),
        'owner_id': int(config_data.get('owner_id', 0)),
        'script_path': config_data.get('script_path', './nostr_media_uploader.sh'),
        'cygwin_root': config_data.get('cygwin_root'),  # Optional: path to Cygwin installation
        'nostr_client_url': config_data.get('nostr_client_url'),  # Optional: URL template for nostr client links
        'channels': config_data.get('channels', {}),
        'use_firefox': use_firefox,
        'cookies_file': cookies_file,
        'disable_cookies_for_sites': config_data.get('disable_cookies_for_sites'),  # Optional: list of domains to disable cookies for
        'script_timeout': script_timeout,  # Timeout for script execution in seconds (default: 360 = 6 minutes)
    }


def find_channel_config(config, chat_id=None, chat_username=None):
    """Find channel configuration matching the given chat_id or username.
    
    Returns the channel config dict if found, None otherwise.
    """
    channels = config.get('channels', {})
    
    if not chat_id and not chat_username:
        return None
    
    chat_id_str = str(chat_id) if chat_id else None
    chat_username_str = chat_username.lstrip('@') if chat_username else None
    
    # Search through channels for a match
    for channel_name, channel_config in channels.items():
        channel_chat_id = channel_config.get('chat_id')
        if not channel_chat_id:
            continue
        
        channel_chat_id_str = str(channel_chat_id).lstrip('@')
        
        # Match by numeric ID
        if chat_id_str and chat_id_str == channel_chat_id_str:
            logger.debug(f"Found channel config '{channel_name}' for chat_id={chat_id_str}")
            return channel_config
        
        # Match by username
        if chat_username_str and chat_username_str == channel_chat_id_str:
            logger.debug(f"Found channel config '{channel_name}' for username={chat_username_str}")
            return channel_config
    
    return None


def extract_urls(text):
    """Extract all URLs from a text message."""
    if not text:
        return []
    return URL_PATTERN.findall(text)


def should_disable_cookies(urls, disable_cookies_for_sites):
    """Check if cookies should be disabled for any of the given URLs.
    
    Args:
        urls: List of URLs to check
        disable_cookies_for_sites: List of domain patterns to match against (e.g., ['facebook.com', 'instagram.com'])
    
    Returns:
        True if any URL matches a domain in the disable list, False otherwise
    """
    if not urls:
        return False
    
    # If disable_cookies_for_sites is None or empty list, don't disable
    if not disable_cookies_for_sites:
        return False
    
    # Convert to list if it's not already
    if not isinstance(disable_cookies_for_sites, list):
        disable_cookies_for_sites = [disable_cookies_for_sites]
    
    # Filter out empty strings
    disable_cookies_for_sites = [p for p in disable_cookies_for_sites if p and p.strip()]
    
    # If list is empty after filtering, don't disable
    if not disable_cookies_for_sites:
        return False
    
    for url in urls:
        # Only check HTTP/HTTPS URLs
        if not url.startswith(('http://', 'https://')):
            continue
        
        # Extract domain from URL
        try:
            # Simple domain extraction - get the hostname part
            parsed = urlparse(url)
            domain = parsed.netloc.lower()
            # Remove port if present
            if ':' in domain:
                domain = domain.split(':')[0]
        except Exception:
            # If parsing fails, try simple string matching
            domain = url.lower()
        
        # Check if domain matches any pattern in the disable list
        for pattern in disable_cookies_for_sites:
            pattern_lower = pattern.lower().strip()
            # Remove leading/trailing dots and whitespace
            pattern_lower = pattern_lower.strip('.')
            
            # Check if domain matches pattern (exact match or ends with pattern)
            if domain == pattern_lower or domain.endswith('.' + pattern_lower):
                logger.info(f"URL {url} matches disable cookies pattern '{pattern}', disabling cookies")
                return True
    
    return False


def extract_extra_text(text, urls):
    """Extract text remaining after URLs are removed."""
    if not text:
        return ""
    
    # Remove all URLs from text
    text_without_urls = text
    for url in urls:
        text_without_urls = text_without_urls.replace(url, '', 1)
    
    # Clean up extra whitespace
    extra_text = ' '.join(text_without_urls.split()).strip()
    return extra_text


def sanitize_subprocess_output(text):
    """Sanitize subprocess output to remove control characters and ANSI escape sequences.
    
    This prevents terminal corruption and command injection from special characters in forwarded
    Telegram content or other sources that may contain ANSI codes, control characters, escape
    sequences, or invalid UTF-8. Removes all escape sequences that terminals might interpret
    as commands, including VT100, ANSI CSI, OSC, DCS, PM, APC, and other terminal control codes.
    
    Args:
        text: Raw subprocess output (string or bytes)
        
    Returns:
        Sanitized string safe for terminal/logging (no executable escape sequences)
    """
    if not text:
        return ''
    
    # Convert bytes to string if needed
    if isinstance(text, bytes):
        try:
            text = text.decode('utf-8', errors='replace')
        except Exception:
            # Fallback: try to decode with latin-1 and replace invalid
            text = text.decode('latin-1', errors='replace')
    
    # Remove all ANSI/VT100 escape sequences that terminals interpret as commands
    # This is comprehensive to prevent any terminal command injection
    
    # 1. CSI (Control Sequence Introducer) sequences: \x1b[...m, \x1b[2J, \x1b[H, etc.
    # Matches: \x1b[ followed by optional parameters and a command character
    text = re.sub(r'\x1b\[[0-9;?]*[a-zA-Z@_!]', '', text)  # CSI sequences with various endings
    text = re.sub(r'\033\[[0-9;?]*[a-zA-Z@_!]', '', text)  # \033[...letter
    text = re.sub(r'\u001b\[[0-9;?]*[a-zA-Z@_!]', '', text)  # Unicode escape
    
    # 2. OSC (Operating System Command) sequences: \x1b]...\x07 or \x1b]...\x1b\\
    # Can be used for terminal window title, clipboard manipulation, etc.
    text = re.sub(r'\x1b\][^\x07\x1b]*(\x07|\x1b\\)', '', text)  # OSC sequences
    text = re.sub(r'\033\][^\x07\x1b]*(\x07|\033\\)', '', text)  # \033 variant
    
    # 3. DCS (Device Control String): \x1bP...\x1b\\
    # Can send commands to terminal devices
    text = re.sub(r'\x1bP[^\x1b]*\x1b\\', '', text)  # DCS sequences
    text = re.sub(r'\033P[^\033]*\033\\', '', text)  # \033 variant
    
    # 4. PM (Privacy Message): \x1b^...\x1b\\
    text = re.sub(r'\x1b\^[^\x1b]*\x1b\\', '', text)  # PM sequences
    text = re.sub(r'\033\^[^\033]*\033\\', '', text)  # \033 variant
    
    # 5. APC (Application Program Command): \x1b_...\x1b\\
    text = re.sub(r'\x1b_[^\x1b]*\x1b\\', '', text)  # APC sequences
    text = re.sub(r'\033_[^\033]*\033\\', '', text)  # \033 variant
    
    # 6. Single-character ESC sequences (VT100/ANSI control functions)
    # These are ESC followed by a single character (no brackets)
    # Examples: \x1bD (IND), \x1bE (NEL), \x1bH (HTS), \x1bM (RI), etc.
    esc_single_chars = r'[DdEeHhMNOPSTUVXZ78=<>]'  # Common single-char ESC sequences
    text = re.sub(r'\x1b' + esc_single_chars, '', text)
    text = re.sub(r'\033' + esc_single_chars, '', text)
    text = re.sub(r'\u001b' + esc_single_chars, '', text)
    
    # 7. ESC > and ESC = (already handled above, but be explicit)
    text = re.sub(r'\x1b[>=]', '', text)
    text = re.sub(r'\033[>=]', '', text)
    
    # 8. Remove any remaining isolated ESC characters (escape sequences we might have missed)
    # This is a catch-all for any ESC not followed by valid sequence characters
    # But we need to be careful not to remove legitimate content
    # We'll remove standalone ESC that aren't part of sequences
    
    # Aggressively remove ALL carriage returns - they cause overwriting in terminals
    # Even \r\n sequences can cause issues in some terminal emulators
    # Convert all \r to \n to preserve line structure
    text = text.replace('\r\n', '\n')  # Normalize Windows line endings first
    text = text.replace('\r', '\n')  # Convert any remaining \r to \n
    
    # Remove other problematic control characters except common ones
    # Keep: \n (newline 10), \t (tab 9)
    # Remove all other C0 control characters (0-31) and DEL (127)
    # These can be interpreted as terminal commands or cause display issues
    control_chars = []
    for i in range(32):
        if i not in (9, 10):  # Keep tab (9) and newline (10)
            control_chars.append(chr(i))
    
    # Also remove DEL (127) - can cause backspace-like behavior
    control_chars.append(chr(127))
    
    # Build regex to remove these control chars
    if control_chars:
        control_pattern = '[' + re.escape(''.join(control_chars)) + ']'
        text = re.sub(control_pattern, '', text)
    
    # Remove null bytes (can terminate strings unexpectedly)
    text = text.replace('\x00', '')
    
    # Remove backspace characters and their effects (can cause text deletion in terminals)
    # Backspace (\x08) followed by any character should remove both
    while '\x08' in text:
        text = re.sub(r'.\x08', '', text)  # Remove char + backspace
        text = text.replace('\x08', '')  # Remove any remaining backspaces
    
    # Remove form feed (\x0c) - can cause page breaks/clearing in terminals
    text = text.replace('\x0c', '\n')
    
    # Remove vertical tab (\x0b) - can cause cursor movement
    text = text.replace('\x0b', '\n')
    
    # Remove any remaining ESC characters (standalone escape chars that might have been missed)
    # This is a safety measure - remove any ESC not already part of a removed sequence
    # But we do this after removing sequences to avoid interfering with sequence matching
    text = text.replace('\x1b', '')
    text = text.replace('\033', '')
    text = text.replace('\u001b', '')
    
    # Normalize excessive whitespace (more than 2 consecutive newlines -> 2 newlines)
    text = re.sub(r'\n{3,}', '\n\n', text)
    
    # Remove trailing whitespace from each line (but keep the line itself)
    lines = text.split('\n')
    lines = [line.rstrip() for line in lines]
    text = '\n'.join(lines)
    
    # Ensure valid UTF-8 and replace any remaining invalid sequences
    try:
        text.encode('utf-8')
    except UnicodeEncodeError:
        # If encoding fails, remove problematic characters
        text = text.encode('utf-8', errors='replace').decode('utf-8', errors='replace')
    
    return text


def extract_event_id(output):
    """Extract event ID from nak output.
    
    nak outputs the event ID after creating an event. We need to find the actual
    Nostr event ID, not file hashes or other hex strings.
    
    The event ID is typically output by nak in JSON format or as a standalone hex string.
    We should exclude hex strings that appear in URLs (like blossom file hashes).
    """
    # First, collect all hex strings that appear in URLs to exclude them
    url_hex = set()
    for url_match in re.finditer(r'https?://[^\s\)]+', output):
        url = url_match.group(0)
        # Extract hex strings from URLs (these are file hashes, not event IDs)
        url_hex.update(re.findall(r'([0-9a-fA-F]{64})', url))
    
    # nak might output JSON with the event - look for complete JSON objects
    # Try to find JSON objects that contain "id", "kind", "pubkey" (event structure)
    json_object_pattern = r'\{[^{}]*"id"\s*:\s*"([0-9a-fA-F]{64})"[^{}]*"kind"\s*:\s*\d+[^{}]*\}'
    json_matches = re.findall(json_object_pattern, output, re.DOTALL)
    if json_matches:
        # Return the last JSON match (most likely the event from nak)
        event_id = json_matches[-1]
        if event_id not in url_hex:
            return event_id
    
    # Look for JSON with "id" field - nak might output just the event ID in JSON
    json_id_patterns = [
        r'\{\s*"id"\s*:\s*"([0-9a-fA-F]{64})"',  # JSON starting with id
        r'"id"\s*:\s*"([0-9a-fA-F]{64})"',  # JSON id field (but not in URLs)
    ]
    
    for pattern in json_id_patterns:
        matches = re.findall(pattern, output)
        if matches:
            # Return the last match that's not in a URL
            for event_id in reversed(matches):
                if event_id not in url_hex:
                    return event_id
    
    # Look for event ID after "Successfully published" or similar success messages
    # nak might output the event ID on a line after success message
    success_patterns = [
        r'Successfully published[^\n]*\n[^\n]*([0-9a-fA-F]{64})',
        r'published[^\n]*event[^\n]*\n[^\n]*([0-9a-fA-F]{64})',
        r'event[^\n]*created[^\n]*\n[^\n]*([0-9a-fA-F]{64})',
    ]
    
    for pattern in success_patterns:
        match = re.search(pattern, output, re.IGNORECASE | re.MULTILINE)
        if match:
            event_id = match.group(1)
            if event_id not in url_hex:
                return event_id
    
    # Look for hex strings near the end of output (nak usually outputs event ID at the end)
    # But exclude common file hashes that appear in URLs
    lines = output.split('\n')
    # Check last 30 lines for event ID
    for line in reversed(lines[-30:]):
        # Skip lines that contain URLs
        if re.search(r'https?://', line):
            continue
        hex_matches = re.findall(r'\b([0-9a-fA-F]{64})\b', line)
        if hex_matches:
            # Return the first match from this line that's not in URLs
            for hex_id in hex_matches:
                if hex_id not in url_hex:
                    return hex_id
    
    # Last resort: look for any 64-char hex string, but exclude ones in URLs
    all_hex = re.findall(r'\b([0-9a-fA-F]{64})\b', output)
    if all_hex:
        # Return the last hex that's not in a URL
        for hex_id in reversed(all_hex):
            if hex_id not in url_hex:
                return hex_id
    
    return None


async def encode_to_nevent(event_id_hex):
    """Encode event ID to nevent format using nak command."""
    if not event_id_hex or len(event_id_hex) != 64:
        return None
    
    try:
        process = await asyncio.create_subprocess_exec(
            'nak', 'encode', 'nevent', event_id_hex,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE
        )
        
        stdout_bytes, stderr_bytes = await process.communicate()
        
        if process.returncode == 0 and stdout_bytes:
            # Decode and clean up output
            nevent = stdout_bytes.decode('utf-8', errors='replace').strip()
            # Take first line in case there are multiple lines
            nevent = nevent.split('\n')[0].strip()
            if nevent.startswith('nevent1'):
                return nevent
            else:
                logger.warning(f"nak encode nevent returned unexpected format: {nevent}")
        else:
            stderr = stderr_bytes.decode('utf-8', errors='replace') if stderr_bytes else ''
            sanitized_stderr = sanitize_subprocess_output(stderr)
            logger.warning(f"nak encode nevent failed: {sanitized_stderr}")
    except Exception as e:
        logger.warning(f"Failed to encode nevent using nak: {e}")
    
    return None


def is_cygwin():
    """Check if running on Cygwin."""
    try:
        # Check for Cygwin-specific environment or commands
        if os.path.exists('/usr/bin/cygpath') or os.path.exists('/cygdrive'):
            return True
        # Check OSTYPE environment variable
        if os.environ.get('OSTYPE', '').startswith('cygwin'):
            return True
        # Try to run cygpath to verify
        result = subprocess.run(
            ['cygpath', '-u', '/'],
            capture_output=True,
            text=True,
            timeout=2
        )
        if result.returncode == 0:
            return True
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
        pass
    
    return False


def find_cygwin_installation():
    """Find Cygwin installation directory.
    
    Returns the path to Cygwin root directory (e.g., C:\\cygwin64 or F:\\cygwin64),
    or None if not found.
    """
    # Common Cygwin installation locations
    common_paths = [
        r'C:\cygwin64',
        r'C:\cygwin',
        r'D:\cygwin64',
        r'D:\cygwin',
        r'E:\cygwin64',
        r'E:\cygwin',
        r'F:\cygwin64',
        r'F:\cygwin',
    ]
    
    # Check if CYGWIN_ROOT environment variable is set
    cygwin_root = os.environ.get('CYGWIN_ROOT') or os.environ.get('CYGWIN_HOME')
    if cygwin_root:
        cygwin_root = os.path.normpath(cygwin_root)
        if os.path.exists(cygwin_root):
            bash_path = os.path.join(cygwin_root, 'bin', 'bash.exe')
            bash_path = os.path.normpath(bash_path)
            if os.path.exists(bash_path):
                return cygwin_root
    
    # Check common locations
    for cygwin_root in common_paths:
        cygwin_root = os.path.normpath(cygwin_root)
        bash_path = os.path.join(cygwin_root, 'bin', 'bash.exe')
        bash_path = os.path.normpath(bash_path)
        if os.path.exists(bash_path):
            return cygwin_root
    
    # Try to detect from PATH if bash.exe is found
    try:
        # On Windows, prevent console window
        startupinfo = None
        if os.name == 'nt':
            startupinfo = subprocess.STARTUPINFO()
            startupinfo.dwFlags |= subprocess.STARTF_USESHOWWINDOW
            startupinfo.wShowWindow = subprocess.SW_HIDE
        
        result = subprocess.run(
            ['where', 'bash.exe'] if os.name == 'nt' else ['which', 'bash'],
            capture_output=True,
            text=True,
            timeout=2,
            startupinfo=startupinfo
        )
        if result.returncode == 0:
            bash_exe_path = result.stdout.strip().split('\n')[0]
            # Extract Cygwin root from path (e.g., C:\cygwin64\bin\bash.exe -> C:\cygwin64)
            if 'cygwin' in bash_exe_path.lower():
                # Try common patterns
                for pattern in [r'\cygwin64\bin', r'\cygwin\bin']:
                    if pattern in bash_exe_path:
                        cygwin_root = bash_exe_path.split(pattern)[0]
                        cygwin_root = os.path.normpath(cygwin_root)
                        if os.path.exists(cygwin_root):
                            return cygwin_root
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
        pass
    
    return None


def get_bash_path(config=None):
    """Get the correct bash path for the current environment.
    
    Args:
        config: Optional config dict that may contain 'cygwin_root'
    
    Returns:
        Path to bash executable (Windows path if running Windows Python, Unix path if running Cygwin Python)
    """
    cygwin_root = None
    # Detect Windows Python - check both os.name and sys.platform for reliability
    is_windows_python = (os.name == 'nt' or sys.platform.startswith('win'))
    
    # First, try to get from config
    if config and config.get('cygwin_root'):
        cygwin_root = config['cygwin_root']
        cygwin_root = os.path.normpath(cygwin_root)
        bash_path = os.path.join(cygwin_root, 'bin', 'bash.exe')
        bash_path = os.path.normpath(bash_path)
        if os.path.exists(bash_path):
            logger.info(f"Using configured Cygwin bash: {bash_path}")
            return bash_path
        logger.warning(f"Configured cygwin_root '{cygwin_root}' not found or bash.exe missing at {bash_path}, trying auto-detection")
    
    # If running Windows Python, we MUST use Windows paths, even if Cygwin is detected
    if is_windows_python:
        # Find Cygwin installation
        if not cygwin_root:
            cygwin_root = find_cygwin_installation()
        
        if cygwin_root:
            # Normalize the path for Windows
            cygwin_root = os.path.normpath(cygwin_root)
            bash_path = os.path.join(cygwin_root, 'bin', 'bash.exe')
            bash_path = os.path.normpath(bash_path)
            
            if os.path.exists(bash_path):
                logger.info(f"Using Cygwin bash from: {bash_path}")
                return bash_path
            else:
                logger.warning(f"Found Cygwin root at {cygwin_root} but bash.exe not found at {bash_path}")
        
        # Default to 'bash' (will use system PATH)
        logger.warning("Could not find Cygwin installation, falling back to 'bash' from PATH")
        return 'bash'
    
    # If running from within Cygwin Python, use Unix paths
    # Check if we're actually running from Cygwin (not just detecting Cygwin exists)
    if is_cygwin() and os.path.exists('/usr/bin/bash'):
        # Try common Cygwin bash locations
        cygwin_bash_paths = [
            '/usr/bin/bash',
            '/bin/bash',
        ]
        for bash_path in cygwin_bash_paths:
            if os.path.exists(bash_path):
                return bash_path
        # Fallback: try to find bash in PATH but prefer /usr/bin
        try:
            # On Windows, prevent console window
            startupinfo = None
            if os.name == 'nt':
                startupinfo = subprocess.STARTUPINFO()
                startupinfo.dwFlags |= subprocess.STARTF_USESHOWWINDOW
                startupinfo.wShowWindow = subprocess.SW_HIDE
            
            result = subprocess.run(
                ['which', 'bash'],
                capture_output=True,
                text=True,
                timeout=2,
                startupinfo=startupinfo
            )
            if result.returncode == 0:
                bash_path = result.stdout.strip()
                if bash_path and os.path.exists(bash_path):
                    return bash_path
                return '/usr/bin/bash'
        except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
            pass
    
    # Default to 'bash' (will use system PATH)
    logger.warning("Could not determine bash path, falling back to 'bash' from PATH")
    return 'bash'


def convert_path_for_cygwin(path, config=None):
    """Convert Windows path to Cygwin path if running on Cygwin or using Cygwin bash.
    
    Args:
        path: Windows path to convert
        config: Optional config dict that may contain 'cygwin_root'
    
    Returns:
        Cygwin-style path if conversion is possible, original path otherwise
    """
    # If running from within Cygwin, use cygpath
    if is_cygwin():
        if not os.path.exists(path):
            return path
        
        try:
            # On Windows, prevent console window
            startupinfo = None
            if os.name == 'nt':
                startupinfo = subprocess.STARTUPINFO()
                startupinfo.dwFlags |= subprocess.STARTF_USESHOWWINDOW
                startupinfo.wShowWindow = subprocess.SW_HIDE
            
            result = subprocess.run(
                ['cygpath', '-u', path],
                capture_output=True,
                text=True,
                timeout=5,
                startupinfo=startupinfo
            )
            if result.returncode == 0:
                return result.stdout.strip()
        except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
            pass
    
    # If using Cygwin bash from Windows Python, convert path manually
    cygwin_root = None
    if config and config.get('cygwin_root'):
        cygwin_root = config['cygwin_root']
    else:
        cygwin_root = find_cygwin_installation()
    
    if cygwin_root and os.name == 'nt':
        # Convert Windows path to Cygwin path
        # e.g., F:\cygwin64\home\user\file -> /home/user/file
        # or F:\other\path\to\file -> /cygdrive/f/other/path/to/file
        cygwin_root_norm = os.path.normpath(cygwin_root).replace('\\', '/')
        path_norm = os.path.normpath(path).replace('\\', '/')
        
        # Check if path is within Cygwin root
        if path_norm.lower().startswith(cygwin_root_norm.lower()):
            # Path is within Cygwin, convert directly
            cygwin_path = path_norm[len(cygwin_root_norm):].replace('\\', '/')
            if cygwin_path.startswith('/'):
                return cygwin_path
            return '/' + cygwin_path
        else:
            # Path is outside Cygwin, use /cygdrive/X/... format
            # Extract drive letter (e.g., F:)
            drive_match = re.match(r'^([A-Za-z]):', path_norm)
            if drive_match:
                drive_letter = drive_match.group(1).lower()
                # Remove drive letter and convert
                rest_path = path_norm[2:].replace('\\', '/')
                return f'/cygdrive/{drive_letter}{rest_path}'
    
    return path


async def download_media_file(bot, file, file_extension=None, max_retries=3, retry_delay=1.0):
    """Download a media file from Telegram and save it to a temporary file.
    
    Args:
        bot: The bot instance to use for downloading
        file: The file object from Telegram (PhotoSize, Video, etc.)
        file_extension: Optional file extension (e.g., 'jpg', 'mp4'). If not provided, will try to detect.
        max_retries: Maximum number of retry attempts (default: 3)
        retry_delay: Initial delay between retries in seconds (default: 1.0)
    
    Returns:
        Path to the temporary file, or None if download failed
    """
    try:
        # Get the file object with retry logic
        file_obj = None
        if hasattr(file, 'file_id'):
            last_exception = None
            for attempt in range(max_retries):
                try:
                    file_obj = await bot.get_file(file.file_id)
                    break
                except (TimedOut, NetworkError) as e:
                    last_exception = e
                    if attempt < max_retries - 1:
                        wait_time = retry_delay * (2 ** attempt)  # Exponential backoff
                        logger.warning(f"get_file attempt {attempt + 1} failed with {type(e).__name__}, retrying in {wait_time}s...")
                        await asyncio.sleep(wait_time)
                    else:
                        logger.error(f"Failed to get_file after {max_retries} attempts: {e}")
                except Exception as e:
                    # For non-network errors, don't retry
                    logger.error(f"Non-retryable error getting file: {e}")
                    raise
            
            if file_obj is None:
                logger.error(f"Could not get file object after {max_retries} attempts. Last error: {last_exception}")
                return None
        else:
            # If it's already a File object
            file_obj = file
        
        # Determine file extension if not provided
        if not file_extension:
            if hasattr(file, 'mime_type') and file.mime_type:
                # Extract extension from mime type
                mime_to_ext = {
                    'image/jpeg': 'jpg',
                    'image/png': 'png',
                    'image/gif': 'gif',
                    'image/webp': 'webp',
                    'video/mp4': 'mp4',
                    'video/quicktime': 'mov',
                    'video/x-msvideo': 'avi',
                }
                file_extension = mime_to_ext.get(file.mime_type, 'bin')
            else:
                # Default based on file path if available
                if hasattr(file_obj, 'file_path') and file_obj.file_path:
                    file_extension = Path(file_obj.file_path).suffix.lstrip('.') or 'bin'
                else:
                    file_extension = 'bin'
        
        # Create temporary file
        temp_file = tempfile.NamedTemporaryFile(delete=False, suffix=f'.{file_extension}')
        temp_path = temp_file.name
        temp_file.close()
        
        # Download the file with retry logic
        last_exception = None
        for attempt in range(max_retries):
            try:
                await file_obj.download_to_drive(temp_path)
                logger.info(f"Downloaded media file to: {temp_path}")
                return temp_path
            except (TimedOut, NetworkError) as e:
                last_exception = e
                if attempt < max_retries - 1:
                    wait_time = retry_delay * (2 ** attempt)  # Exponential backoff
                    logger.warning(f"download_to_drive attempt {attempt + 1} failed with {type(e).__name__}, retrying in {wait_time}s...")
                    await asyncio.sleep(wait_time)
                    # Clean up partial download if it exists
                    try:
                        if os.path.exists(temp_path):
                            os.unlink(temp_path)
                    except Exception:
                        pass
                else:
                    logger.error(f"Failed to download file after {max_retries} attempts: {e}")
            except Exception as e:
                # For non-network errors, don't retry
                logger.error(f"Non-retryable error downloading file: {e}")
                # Clean up temporary file on error
                try:
                    if os.path.exists(temp_path):
                        os.unlink(temp_path)
                except Exception:
                    pass
                raise
        
        # If we get here, all retries failed
        logger.error(f"Could not download file after {max_retries} attempts. Last error: {last_exception}")
        # Clean up temporary file
        try:
            if os.path.exists(temp_path):
                os.unlink(temp_path)
        except Exception:
            pass
        return None
    except Exception as e:
        logger.exception(f"Error downloading media file: {e}")
        return None


def build_command(profile_name, script_path, urls, extra_text, use_firefox=True, cookies_file=None, config=None, nsfw=False, disable_cookies_for_sites=None):
    """Build the command to execute nostr_media_uploader.sh.
    
    Args:
        profile_name: Profile name to use
        script_path: Path to nostr_media_uploader.sh
        urls: List of URLs or file paths
        extra_text: Additional text/description
        use_firefox: Whether to use Firefox cookies (default: True)
        cookies_file: Path to cookies file (takes precedence over use_firefox)
        config: Config dict (for path conversion)
        nsfw: Whether to add --nsfw flag (default: False)
        disable_cookies_for_sites: List of domain patterns to disable cookies for (default: None)
    """
    # Convert script path to absolute path
    script_path = Path(script_path)
    if not script_path.is_absolute():
        script_dir = Path(__file__).parent.absolute()
        script_path = script_dir / script_path
    
    script_path = str(script_path)
    
    # Convert to Cygwin path if needed (using config if available)
    script_path = convert_path_for_cygwin(script_path, config)
    
    # Get the correct bash path for the environment
    bash_path = get_bash_path(config)
    
    # Validate bash path exists
    if not os.path.exists(bash_path) and os.path.isabs(bash_path):
        raise FileNotFoundError(f"Bash executable not found: {bash_path}")
    
    logger.info(f"Using bash: {bash_path}")
    logger.info(f"Script path: {script_path}")
    
    # Check if cookies should be disabled for any URLs
    disable_cookies = should_disable_cookies(urls, disable_cookies_for_sites)
    if disable_cookies_for_sites:
        logger.debug(f"Checking disable_cookies_for_sites: {disable_cookies_for_sites} against URLs: {urls}, result: {disable_cookies}")
    
    # Build command: bash script_path -p profile_name [--cookies FILE|--firefox] [--nsfw] url1 url2 ... "extra_text"
    cmd = [bash_path, script_path, '-p', profile_name]
    
    # Use cookies file if provided and not disabled (takes precedence over --firefox)
    if cookies_file and not disable_cookies:
        # Convert cookies file path to Cygwin path if needed
        cookies_path = convert_path_for_cygwin(cookies_file, config)
        cmd.extend(['--cookies', cookies_path])
        logger.info(f"Adding --cookies parameter with file: {cookies_path}")
    elif use_firefox and not disable_cookies:
        # Only add --firefox if cookies_file is not set and cookies are not disabled
        cmd.append('--firefox')
        logger.info("Adding --firefox parameter")
    elif disable_cookies:
        logger.info("Cookies disabled for this request (URL matches disable_cookies_for_sites pattern)")
    
    # Add --nsfw if enabled
    if nsfw:
        cmd.append('--nsfw')
        logger.info("Adding --nsfw parameter")
    
    # Add --nocomment if there is extra text after URLs
    if extra_text and extra_text.strip():
        cmd.append('--nocomment')
        logger.info("Adding --nocomment parameter (extra text detected)")
    
    # Add all URLs or file paths as separate arguments
    # Convert file paths to Cygwin paths if needed
    for item in urls:
        # Check if it's a file path (not a URL)
        if not item.startswith(('http://', 'https://')):
            # It's a file path, convert to Cygwin path if needed
            item = convert_path_for_cygwin(item, config)
        cmd.append(item)
    
    # Add extra text if present
    if extra_text:
        cmd.append(extra_text)
    
    return cmd


async def get_cygwin_pid(windows_pid):
    """Map a Windows PID to a Cygwin PID using ps command.
    
    Args:
        windows_pid: Windows process ID
    
    Returns:
        Cygwin PID if found, None otherwise
    """
    if not IS_CYGWIN:
        return windows_pid  # Not Cygwin, return as-is
    
    try:
        # Use ps to find the Cygwin PID for this Windows PID
        # Format: ps -W -p <windows_pid> -o pid=,ppid=,winpid=
        # We want the pid column (Cygwin PID) where winpid matches
        proc = await asyncio.create_subprocess_exec(
            'ps', '-W', '-p', str(windows_pid), '-o', 'pid=,winpid=',
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.DEVNULL
        )
        stdout, _ = await asyncio.wait_for(proc.communicate(), timeout=2.0)
        
        if proc.returncode == 0 and stdout:
            # Parse output: lines are like "12345 67890" (cygwin_pid winpid)
            for line in stdout.decode('utf-8', errors='ignore').strip().split('\n'):
                parts = line.strip().split()
                if len(parts) >= 2:
                    cygwin_pid = parts[0].strip()
                    winpid = parts[1].strip()
                    if winpid == str(windows_pid):
                        logger.debug(f"Mapped Windows PID {windows_pid} to Cygwin PID {cygwin_pid}")
                        return int(cygwin_pid)
        
        logger.debug(f"Could not map Windows PID {windows_pid} to Cygwin PID (process may not exist in Cygwin)")
        return None
    except (asyncio.TimeoutError, FileNotFoundError, ValueError, Exception) as e:
        logger.debug(f"Error mapping Windows PID {windows_pid} to Cygwin PID: {e}")
        return None


async def kill_process_tree(pid, timeout=5.0):
    """Kill a process and all its children recursively.
    
    Args:
        pid: Process ID to kill
        timeout: Time to wait for graceful termination before force kill (seconds)
    
    Returns:
        True if successful, False otherwise
    """
    try:
        if not pid:
            return False
        
        if not PSUTIL_AVAILABLE:
            logger.warning("psutil not available, using basic process kill (children may remain). Install with: pip install psutil")
            # Fallback: try to kill using signal on Unix or taskkill on Windows
            try:
                if os.name == 'nt':
                    # Windows: use taskkill to kill process tree
                    # Use async subprocess to avoid blocking on KeyboardInterrupt
                    try:
                        proc = await asyncio.create_subprocess_exec(
                            'taskkill', '/F', '/T', '/PID', str(pid),
                            stdout=asyncio.subprocess.DEVNULL,
                            stderr=asyncio.subprocess.DEVNULL
                        )
                        await asyncio.wait_for(proc.wait(), timeout=5.0)
                    except (asyncio.TimeoutError, KeyboardInterrupt):
                        # If interrupted or timeout, try to kill the taskkill process itself
                        try:
                            if proc and proc.returncode is None:
                                proc.kill()
                                await proc.wait()
                        except Exception:
                            pass
                else:
                    # Unix: send SIGINT to parent first to match Control-C behavior
                    try:
                        os.kill(pid, signal.SIGINT)
                        logger.debug(f"Sent SIGINT to parent PID {pid} (matching Control-C), waiting for cleanup handlers...")
                        await asyncio.sleep(2)  # Give parent time to run cleanup handlers
                        
                        # Check if process still exists
                        try:
                            os.kill(pid, 0)  # Check if process exists
                            # Still running, send SIGTERM to process group (including children)
                            os.killpg(os.getpgid(pid), signal.SIGTERM)
                            await asyncio.sleep(1)
                            # Force kill if still running
                            os.killpg(os.getpgid(pid), signal.SIGKILL)
                        except ProcessLookupError:
                            pass  # Process already dead
                    except ProcessLookupError:
                        pass  # Already dead
            except (KeyboardInterrupt, Exception) as e:
                if isinstance(e, KeyboardInterrupt):
                    logger.warning("Process kill interrupted by KeyboardInterrupt, continuing cleanup...")
                else:
                    logger.debug(f"Basic kill failed: {e}")
            return True
        
        # Get the process object
        try:
            parent = psutil.Process(pid)
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            logger.debug(f"Process {pid} not found or access denied")
            return False
        
        # Get all child processes recursively BEFORE sending signal
        # We'll check if they're still running after parent exits
        children = parent.children(recursive=True)
        child_pids = [p.pid for p in children]
        
        # Log detailed process tree information
        logger.warning(f"[PROCESS TREE] ========== Starting kill operation ==========")
        logger.warning(f"[PROCESS TREE] Parent process:")
        try:
            parent_cmd = ' '.join(parent.cmdline()) if hasattr(parent, 'cmdline') else 'N/A'
            logger.warning(f"[PROCESS TREE]   PID: {pid} (Windows PID)")
            logger.warning(f"[PROCESS TREE]   Name: {parent.name()}")
            logger.warning(f"[PROCESS TREE]   Command: {parent_cmd}")
            if IS_CYGWIN:
                cygwin_pid = await get_cygwin_pid(pid)
                if cygwin_pid:
                    logger.warning(f"[PROCESS TREE]   Cygwin PID: {cygwin_pid}")
                else:
                    logger.warning(f"[PROCESS TREE]   Cygwin PID: <could not map>")
        except (psutil.NoSuchProcess, psutil.AccessDenied) as e:
            logger.warning(f"[PROCESS TREE]   Error getting parent info: {e}")
        
        logger.warning(f"[PROCESS TREE] Child processes: {len(children)}")
        if children:
            for i, child in enumerate(children, 1):
                try:
                    child_cmd = ' '.join(child.cmdline()) if hasattr(child, 'cmdline') else 'N/A'
                    logger.warning(f"[PROCESS TREE]   Child {i}:")
                    logger.warning(f"[PROCESS TREE]     Windows PID: {child.pid}")
                    logger.warning(f"[PROCESS TREE]     Name: {child.name()}")
                    logger.warning(f"[PROCESS TREE]     Command: {child_cmd}")
                    if IS_CYGWIN:
                        child_cygwin_pid = await get_cygwin_pid(child.pid)
                        if child_cygwin_pid:
                            logger.warning(f"[PROCESS TREE]     Cygwin PID: {child_cygwin_pid}")
                        else:
                            logger.warning(f"[PROCESS TREE]     Cygwin PID: <could not map>")
                except (psutil.NoSuchProcess, psutil.AccessDenied) as e:
                    logger.warning(f"[PROCESS TREE]   Child {i}: PID {child.pid} (Windows) | Error: {e}")
        
        logger.info(f"Killing process tree: parent PID {pid} and {len(children)} child process(es)")
        
        # Step 1: Send SIGINT to parent process first to allow it to run cleanup handlers
        # SIGINT matches Control-C behavior exactly, triggering the same trap handlers
        # This gives bash scripts time to execute their trap handlers (e.g., cleanup function)
        try:
            # On Windows, subprocesses launched via bash.exe are ALWAYS Cygwin processes
            # So we should use Cygwin kill methods, not Windows methods
            if os.name == 'nt' or IS_CYGWIN:
                # Cygwin: map Windows PID to Cygwin PID, then use kill command
                cygwin_pid = await get_cygwin_pid(pid)
                if cygwin_pid:
                    try:
                        logger.warning(f"[KILL_PROCESS_TREE] Platform: Cygwin (Windows subprocess) | Method: 'kill -INT' command | Windows PID: {pid} -> Cygwin PID: {cygwin_pid}")
                        kill_proc = await asyncio.create_subprocess_exec(
                            'kill', '-INT', str(cygwin_pid),
                            stdout=asyncio.subprocess.DEVNULL,
                            stderr=asyncio.subprocess.DEVNULL
                        )
                        await asyncio.wait_for(kill_proc.wait(), timeout=2.0)
                        logger.debug(f"Sent SIGINT to parent process (Windows PID {pid}, Cygwin PID {cygwin_pid}) via Cygwin kill command (matching Control-C), waiting for cleanup handlers...")
                    except (asyncio.TimeoutError, FileNotFoundError, ProcessLookupError) as kill_err:
                        # Fallback to psutil send_signal if kill command fails
                        logger.warning(f"[KILL_PROCESS_TREE] Platform: Cygwin (Windows subprocess) | Method: psutil.send_signal() (fallback - kill command failed: {kill_err}) | Windows PID: {pid}")
                        parent.send_signal(signal.SIGINT)
                        logger.debug(f"Sent SIGINT to parent process {pid} via psutil (fallback), waiting for cleanup handlers...")
                else:
                    # Could not map PID, fallback to psutil
                    logger.warning(f"[KILL_PROCESS_TREE] Platform: Cygwin (Windows subprocess) | Method: psutil.send_signal() (fallback - PID mapping failed) | Windows PID: {pid}")
                    parent.send_signal(signal.SIGINT)
                    logger.debug(f"Sent SIGINT to parent process {pid} via psutil (fallback), waiting for cleanup handlers...")
            else:
                # Linux: use psutil send_signal
                logger.warning(f"[KILL_PROCESS_TREE] Platform: Linux | Method: psutil.send_signal() (SIGINT) | PID: {pid}")
                parent.send_signal(signal.SIGINT)
        except (psutil.NoSuchProcess, psutil.AccessDenied) as e:
            logger.debug(f"Could not signal parent process {pid}: {e}")
        
        # Wait for parent to handle signal and potentially exit gracefully
        # Give it more time if there are many children (they need to be cleaned up)
        wait_time = min(timeout, max(2.0, len(children) * 0.5))
        try:
            # Use polling with asyncio.sleep to allow KeyboardInterrupt to be handled
            start_time = time.time()
            while parent.is_running() and (time.time() - start_time) < wait_time:
                try:
                    await asyncio.sleep(0.1)
                except (KeyboardInterrupt, asyncio.CancelledError):
                    # If interrupted, break and proceed to force kill
                    logger.warning("Process wait interrupted, proceeding to force kill...")
                    break
            
            if not parent.is_running():
                signal_name = "SIGINT" if os.name != 'nt' else "SIGTERM"
                logger.info(f"Parent process {pid} exited gracefully after receiving {signal_name}")
                
                # Parent exited, wait longer for children to be cleaned up by parent's cleanup handlers
                # Bash scripts with cleanup handlers need time to actually execute the cleanup
                # Some children might be in the middle of cleanup operations
                logger.debug("Waiting for parent's cleanup handlers to finish cleaning up children...")
                await asyncio.sleep(3.0)  # Increased wait time for cleanup to complete
                
                # Check if any of the known child processes are still running
                # The parent's cleanup handler should have killed them, but verify
                still_running_children = []
                for child_pid in child_pids:
                    try:
                        child_proc = psutil.Process(child_pid)
                        if child_proc.is_running():
                            still_running_children.append(child_proc)
                    except (psutil.NoSuchProcess, psutil.AccessDenied):
                        pass  # Child already dead, which is what we want
                
                if still_running_children:
                    logger.info(f"Parent exited but {len(still_running_children)} child process(es) still running, waiting for cleanup to finish...")
                    # Wait longer for them to exit on their own (they might be in cleanup)
                    # Children might be cleaning up temp files, etc.
                    try:
                        logger.debug("Waiting up to 5s for children to finish cleanup...")
                        gone, still_alive = psutil.wait_procs(still_running_children, timeout=5.0)
                        if still_alive:
                            logger.warning(f"Force killing {len(still_alive)} remaining child process(es) after cleanup timeout...")
                            # Give them one last chance (they might be almost done)
                            await asyncio.sleep(1.0)
                            # Re-check - they might have finished
                            still_alive = [p for p in still_alive if p.is_running()]
                            for proc in still_alive:
                                try:
                                    if IS_CYGWIN:
                                        # Cygwin: map Windows PID to Cygwin PID, then use kill -KILL command
                                        cygwin_pid = await get_cygwin_pid(proc.pid)
                                        if cygwin_pid:
                                            try:
                                                logger.warning(f"[FORCE KILL CHILD] Platform: Cygwin | Method: 'kill -KILL' command | Windows PID: {proc.pid} -> Cygwin PID: {cygwin_pid}")
                                                kill_proc = await asyncio.create_subprocess_exec(
                                                    'kill', '-KILL', str(cygwin_pid),
                                                    stdout=asyncio.subprocess.DEVNULL,
                                                    stderr=asyncio.subprocess.DEVNULL
                                                )
                                                await asyncio.wait_for(kill_proc.wait(), timeout=1.0)
                                                logger.debug(f"Force killed child process (Windows PID {proc.pid}, Cygwin PID {cygwin_pid}) via Cygwin kill -KILL command")
                                            except (asyncio.TimeoutError, FileNotFoundError, ProcessLookupError) as kill_err:
                                                # Fallback to psutil kill
                                                logger.warning(f"[FORCE KILL CHILD] Platform: Cygwin | Method: psutil.kill() (fallback - kill command failed: {kill_err}) | Windows PID: {proc.pid}")
                                                proc.kill()
                                        else:
                                            # Could not map PID, fallback to psutil
                                            logger.warning(f"[FORCE KILL CHILD] Platform: Cygwin | Method: psutil.kill() (fallback - PID mapping failed) | Windows PID: {proc.pid}")
                                            proc.kill()
                                    else:
                                        proc.kill()
                                except (psutil.NoSuchProcess, psutil.AccessDenied):
                                    pass
                    except Exception as e:
                        logger.warning(f"Error waiting for children: {e}")
                
                return True
            else:
                # Parent still running after wait_time, will proceed to Step 2
                elapsed = time.time() - start_time
                logger.warning(f"Parent process {pid} did not exit within {elapsed:.1f}s, proceeding to force kill...")
        except (KeyboardInterrupt, asyncio.CancelledError):
            # If interrupted during wait, proceed to force kill
            logger.warning("Process wait interrupted, proceeding to force kill...")
        except Exception as e:
            logger.warning(f"Error waiting for parent process: {e}, proceeding to force kill...")
        
        # Step 2: If parent didn't exit, get fresh list of children and kill everything
        try:
            if parent.is_running():
                # Get fresh list of children (in case they changed)
                children = parent.children(recursive=True)
                all_procs = [parent] + children
                
                logger.warning(f"[PROCESS TREE] Parent still running, force terminating {len(all_procs)} process(es) in tree:")
                logger.warning(f"[PROCESS TREE]   Parent: PID {parent.pid} (Windows) | Name: {parent.name()}")
                if children:
                    logger.warning(f"[PROCESS TREE]   Children ({len(children)}):")
                    for i, child in enumerate(children, 1):
                        try:
                            child_cmd = ' '.join(child.cmdline()) if hasattr(child, 'cmdline') else 'N/A'
                            logger.warning(f"[PROCESS TREE]     Child {i}: PID {child.pid} (Windows) | Name: {child.name()} | Command: {child_cmd}")
                        except (psutil.NoSuchProcess, psutil.AccessDenied):
                            logger.warning(f"[PROCESS TREE]     Child {i}: PID {child.pid} (Windows) | Name: <access denied>")
                
                logger.info(f"Force terminating {len(all_procs)} process(es) in tree...")
                # Terminate all remaining processes (use SIGINT on Unix to match Control-C)
                for proc in all_procs:
                    try:
                        proc_name = proc.name()
                        proc_cmd = ' '.join(proc.cmdline()) if hasattr(proc, 'cmdline') else 'N/A'
                        logger.warning(f"[PROCESS TREE]   Sending SIGINT to: PID {proc.pid} (Windows) | Name: {proc_name} | Command: {proc_cmd}")
                    except (psutil.NoSuchProcess, psutil.AccessDenied):
                        proc_name = "<access denied>"
                        proc_cmd = "N/A"
                    try:
                        # On Windows, subprocesses launched via bash.exe are ALWAYS Cygwin processes
                        if os.name == 'nt' or IS_CYGWIN:
                            # Cygwin: map Windows PID to Cygwin PID, then use kill command
                            cygwin_pid = await get_cygwin_pid(proc.pid)
                            if cygwin_pid:
                                try:
                                    logger.warning(f"[FORCE TERMINATE] Platform: Cygwin | Method: 'kill -INT' command | Windows PID: {proc.pid} -> Cygwin PID: {cygwin_pid}")
                                    kill_proc = await asyncio.create_subprocess_exec(
                                        'kill', '-INT', str(cygwin_pid),
                                        stdout=asyncio.subprocess.DEVNULL,
                                        stderr=asyncio.subprocess.DEVNULL
                                    )
                                    await asyncio.wait_for(kill_proc.wait(), timeout=1.0)
                                    logger.debug(f"Sent SIGINT to process (Windows PID {proc.pid}, Cygwin PID {cygwin_pid}) via Cygwin kill command")
                                except (asyncio.TimeoutError, FileNotFoundError, ProcessLookupError) as kill_err:
                                    # Fallback to psutil if kill command fails
                                    logger.warning(f"[FORCE TERMINATE] Platform: Cygwin | Method: psutil.send_signal() (fallback - kill command failed: {kill_err}) | Windows PID: {proc.pid}")
                                    proc.send_signal(signal.SIGINT)
                            else:
                                # Could not map PID, fallback to psutil
                                logger.warning(f"[FORCE TERMINATE] Platform: Cygwin | Method: psutil.send_signal() (fallback - PID mapping failed) | Windows PID: {proc.pid}")
                                proc.send_signal(signal.SIGINT)
                        else:
                            proc.send_signal(signal.SIGINT)
                    except (psutil.NoSuchProcess, psutil.AccessDenied) as e:
                        logger.debug(f"Could not signal process {proc.pid}: {e}")
                
                # Wait for graceful termination
                remaining_timeout = max(2.0, timeout - wait_time)
                try:
                    gone, still_alive = psutil.wait_procs(all_procs, timeout=remaining_timeout)
                    if still_alive:
                        logger.warning(f"Force killing {len(still_alive)} process(es) that didn't terminate...")
                except Exception as e:
                    logger.warning(f"Error waiting for processes: {e}")
                    still_alive = all_procs
                
                # Step 3: Force kill any processes that didn't terminate
                for proc in still_alive:
                    try:
                        if IS_CYGWIN:
                            # Cygwin: map Windows PID to Cygwin PID, then use kill -KILL command
                            cygwin_pid = await get_cygwin_pid(proc.pid)
                            if cygwin_pid:
                                try:
                                    logger.warning(f"[FORCE KILL] Platform: Cygwin | Method: 'kill -KILL' command | Windows PID: {proc.pid} -> Cygwin PID: {cygwin_pid}")
                                    kill_proc = await asyncio.create_subprocess_exec(
                                        'kill', '-KILL', str(cygwin_pid),
                                        stdout=asyncio.subprocess.DEVNULL,
                                        stderr=asyncio.subprocess.DEVNULL
                                    )
                                    await asyncio.wait_for(kill_proc.wait(), timeout=1.0)
                                except (asyncio.TimeoutError, FileNotFoundError, ProcessLookupError) as kill_err:
                                    # Fallback to psutil kill
                                    logger.warning(f"[FORCE KILL] Platform: Cygwin | Method: psutil.kill() (fallback - kill command failed: {kill_err}) | Windows PID: {proc.pid}")
                                    proc.kill()
                            else:
                                # Could not map PID, fallback to psutil
                                logger.warning(f"[FORCE KILL] Platform: Cygwin | Method: psutil.kill() (fallback - PID mapping failed) | Windows PID: {proc.pid}")
                                proc.kill()
                        else:
                            logger.warning(f"[FORCE KILL] Platform: Linux | Method: proc.kill() (SIGKILL) | PID: {proc.pid}")
                            proc.kill()
                    except (psutil.NoSuchProcess, psutil.AccessDenied) as e:
                        logger.debug(f"Could not kill process {proc.pid}: {e}")
                
                # Final wait
                try:
                    psutil.wait_procs(still_alive, timeout=2.0)
                except Exception:
                    pass
        except (KeyboardInterrupt, asyncio.CancelledError):
            logger.warning("Process tree kill interrupted, but processes may have been killed")
            return True
        except Exception as e:
            logger.error(f"Error in Step 2 of process tree kill: {e}")
        
        logger.info(f"Successfully killed process tree for PID {pid}")
        return True
        
    except Exception as e:
        logger.error(f"Error killing process tree for PID {pid}: {e}")
        return False


async def _wait_for_read_task_and_collect_output(read_task, chunks_stdout, chunks_stderr, signal_type="signal"):
    """Wait for read_task to complete and collect output.
    
    This is used for both timeout and KeyboardInterrupt cases to ensure
    identical behavior when waiting for process to exit and collecting output.
    
    Args:
        read_task: The asyncio task that's reading from process streams
        chunks_stdout: List of stdout chunks collected so far
        chunks_stderr: List of stderr chunks collected so far
        signal_type: Type of signal sent ("timeout" or "interrupt") for logging
    
    Returns:
        Tuple of (stdout_bytes, stderr_bytes) collected from read_task
    """
    # Wait for read_task to complete (which will happen when process exits)
    # For interrupts (Control-C), use shorter timeout since user wants quick shutdown
    # For timeouts, use longer timeout to allow cleanup handlers to run
    timeout = 2.0 if signal_type == "interrupt" else 15.0
    if read_task and not read_task.done():
        try:
            await asyncio.wait_for(read_task, timeout=timeout)
            logger.debug(f"Process exited after {signal_type} signal, cleanup handlers should have run")
        except asyncio.TimeoutError:
            logger.warning(f"Process did not exit after {signal_type} signal within {timeout}s, will force kill")
            # Cancel read_task since it's taking too long
            # This will also cancel nested stream reading tasks
            read_task.cancel()
            try:
                await read_task
            except (asyncio.CancelledError, KeyboardInterrupt):
                pass
            # Give a moment for nested tasks to finish cancelling (but shorter for interrupts)
            try:
                await asyncio.sleep(0.1 if signal_type == "interrupt" else 0.1)
            except (asyncio.CancelledError, RuntimeError):
                # Event loop might be closing - that's okay
                pass
    
    # Collect the data (read_task may have continued reading)
    stdout_bytes = b''.join(chunks_stdout)
    stderr_bytes = b''.join(chunks_stderr)
    
    return stdout_bytes, stderr_bytes


async def _kill_process_and_read_remaining_output(process, stdout_bytes, stderr_bytes):
    """Helper function to kill process tree and read remaining output.
    
    This is used for both timeout and KeyboardInterrupt cases to ensure
    identical cleanup behavior.
    
    Args:
        process: The subprocess to kill
        stdout_bytes: Existing stdout bytes (will be updated with remaining output)
        stderr_bytes: Existing stderr bytes (will be updated with remaining output)
    
    Returns:
        Tuple of (stdout_bytes, stderr_bytes) with any remaining output appended
    """
    # Kill the process tree (parent and all children)
    try:
        if process and process.pid:
            # Kill the entire process tree
            killed = await kill_process_tree(process.pid, timeout=5.0)
            if not killed:
                # Fallback: try the old method if psutil approach failed
                logger.warning("Process tree kill failed, trying standard kill...")
                try:
                    process.terminate()
                    try:
                        await asyncio.wait_for(process.wait(), timeout=5.0)
                    except (asyncio.TimeoutError, KeyboardInterrupt):
                        process.kill()
                        try:
                            await process.wait()
                        except (asyncio.CancelledError, KeyboardInterrupt):
                            pass  # Already interrupted
                except (KeyboardInterrupt, Exception) as kill_err:
                    if isinstance(kill_err, KeyboardInterrupt):
                        logger.warning("Process kill interrupted, continuing...")
                    else:
                        logger.error(f"Fallback kill also failed: {kill_err}")
        else:
            logger.warning("Process PID not available for killing")
    except (KeyboardInterrupt, Exception) as kill_error:
        if isinstance(kill_error, KeyboardInterrupt):
            logger.warning("Process tree kill interrupted by KeyboardInterrupt, continuing cleanup...")
        else:
            logger.error(f"Error killing process tree: {kill_error}")
    
    # After killing, try to read any remaining output from streams
    # Cleanup handlers might have written to stdout/stderr during cleanup
    # We need to read this output to see cleanup messages
    logger.debug("Reading any remaining output from streams after process kill (cleanup handlers may have written)...")
    try:
        # Wait longer for cleanup handlers to write output (they might be running)
        # The cleanup process might take a moment to flush output
        await asyncio.sleep(2.0)  # Give cleanup handlers time to write
        
        # Try to read remaining data from stdout
        remaining_stdout = b''
        if process.stdout:
            try:
                # Try reading with multiple attempts since data might arrive after cleanup
                for attempt in range(3):  # Try up to 3 times
                    try:
                        # Check if stream is readable
                        if hasattr(process.stdout, 'at_eof') and process.stdout.at_eof():
                            break
                        
                        chunk = await asyncio.wait_for(process.stdout.read(8192), timeout=1.0)
                        if not chunk:
                            # No data yet, wait a bit more if not last attempt
                            if attempt < 2:
                                await asyncio.sleep(0.5)
                                continue
                            break
                        remaining_stdout += chunk
                        # Got some data, continue reading
                    except (asyncio.TimeoutError, asyncio.CancelledError):
                        # Timeout or cancelled, might be more data later
                        if attempt < 2:
                            await asyncio.sleep(0.5)
                            continue
                        break
                    except Exception as e:
                        logger.debug(f"Error reading stdout chunk: {e}")
                        break
            except Exception as e:
                logger.debug(f"Error reading remaining stdout: {e}")
            
            if remaining_stdout:
                stdout_bytes += remaining_stdout
                logger.info(f"Read {len(remaining_stdout)} additional bytes from stdout after kill (likely cleanup handler output)")
        
        # Try to read remaining data from stderr
        remaining_stderr = b''
        if process.stderr:
            try:
                # Try reading with multiple attempts since data might arrive after cleanup
                for attempt in range(3):  # Try up to 3 times
                    try:
                        # Check if stream is readable
                        if hasattr(process.stderr, 'at_eof') and process.stderr.at_eof():
                            break
                        
                        chunk = await asyncio.wait_for(process.stderr.read(8192), timeout=1.0)
                        if not chunk:
                            # No data yet, wait a bit more if not last attempt
                            if attempt < 2:
                                await asyncio.sleep(0.5)
                                continue
                            break
                        remaining_stderr += chunk
                        # Got some data, continue reading
                    except (asyncio.TimeoutError, asyncio.CancelledError):
                        # Timeout or cancelled, might be more data later
                        if attempt < 2:
                            await asyncio.sleep(0.5)
                            continue
                        break
                    except Exception as e:
                        logger.debug(f"Error reading stderr chunk: {e}")
                        break
            except Exception as e:
                logger.debug(f"Error reading remaining stderr: {e}")
            
            if remaining_stderr:
                stderr_bytes += remaining_stderr
                logger.info(f"Read {len(remaining_stderr)} additional bytes from stderr after kill (likely cleanup handler output)")
    except Exception as e:
        logger.debug(f"Error reading remaining output: {e}")
    
    return stdout_bytes, stderr_bytes


async def execute_script(cmd, cwd=None, timeout=None):
    """Execute the script and capture output.
    
    Args:
        cmd: Command to execute as a list
        cwd: Working directory (optional)
        timeout: Timeout in seconds (optional, default: None = no timeout)
    
    Returns:
        Dictionary with returncode, stdout, stderr, and success flag
    """
    process = None
    try:
        # Log full command for debugging
        logger.info(f"Executing command: {cmd}")
        logger.info(f"Command string: {' '.join(str(arg) for arg in cmd)}")
        if timeout:
            logger.info(f"Timeout set to {timeout} seconds")
        
        # Validate first argument (executable) exists if it's an absolute path
        executable = cmd[0] if cmd else None
        if executable and os.path.isabs(executable) and not os.path.exists(executable):
            error_msg = f"Executable not found: {executable}"
            logger.error(error_msg)
            return {
                'returncode': -1,
                'stdout': '',
                'stderr': error_msg,
                'success': False
            }
        
        # On Windows, prevent console window from appearing
        startupinfo = None
        if os.name == 'nt':
            startupinfo = subprocess.STARTUPINFO()
            startupinfo.dwFlags |= subprocess.STARTF_USESHOWWINDOW
            startupinfo.wShowWindow = subprocess.SW_HIDE
        
        # Execute subprocess (works on both Windows and Linux)
        # On Unix, create process in its own process group so SIGINT works like Control-C
        if os.name == 'nt':
            process = await asyncio.create_subprocess_exec(
                *cmd,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
                cwd=cwd or Path(__file__).parent,
                startupinfo=startupinfo
            )
        else:
            # On Unix, try to create process in its own process group (like a foreground process)
            # This allows SIGINT to work exactly like Control-C
            # Note: Cygwin has limited process group support, so we handle it gracefully
            def preexec_fn():
                # Create new process group (like a foreground process)
                # On Cygwin, this might not work or work differently
                try:
                    os.setsid()
                except OSError:
                    # On Cygwin, setsid might not be available or work differently
                    # Just continue without it - we'll send signals directly
                    pass
            
            process = await asyncio.create_subprocess_exec(
                *cmd,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
                cwd=cwd or Path(__file__).parent,
                preexec_fn=preexec_fn if not IS_CYGWIN else None  # Skip on Cygwin
            )
        
        # Track the process for cleanup on shutdown
        if process and process.pid:
            running_processes[process.pid] = {'process': process, 'cmd': cmd}
            logger.debug(f"Tracking process PID {process.pid}: {cmd[0]}")
        
        # Wait for process completion with optional timeout
        stdout_bytes = b''
        stderr_bytes = b''
        timed_out = False
        interrupt_reason = None  # Store reason for error message formatting
        
        if timeout:
            # Use manual stream reading to capture partial output on timeout
            chunks_stdout = []
            chunks_stderr = []
            
            async def read_streams():
                """Read from both streams concurrently while waiting for process."""
                nonlocal chunks_stdout, chunks_stderr
                
                stream_tasks = []
                
                async def read_stdout():
                    if process.stdout:
                        try:
                            while True:
                                chunk = await process.stdout.read(8192)
                                if not chunk:
                                    break
                                chunks_stdout.append(chunk)
                        except (asyncio.CancelledError, Exception):
                            pass  # Stream closed, cancelled, or error
                
                async def read_stderr():
                    if process.stderr:
                        try:
                            while True:
                                chunk = await process.stderr.read(8192)
                                if not chunk:
                                    break
                                chunks_stderr.append(chunk)
                        except (asyncio.CancelledError, Exception):
                            pass  # Stream closed, cancelled, or error
                
                # Start reading streams and waiting for process concurrently
                if process.stdout:
                    stream_tasks.append(asyncio.create_task(read_stdout()))
                if process.stderr:
                    stream_tasks.append(asyncio.create_task(read_stderr()))
                
                try:
                    # Wait for process to finish
                    await process.wait()
                    
                    # Wait for streams to finish reading (they'll hit EOF)
                    if stream_tasks:
                        await asyncio.gather(*stream_tasks, return_exceptions=True)
                except asyncio.CancelledError:
                    # If read_streams is cancelled, cancel all stream tasks
                    for task in stream_tasks:
                        if not task.done():
                            task.cancel()
                    # Wait for stream tasks to finish cancelling
                    if stream_tasks:
                        await asyncio.gather(*stream_tasks, return_exceptions=True)
                    raise
            
            # Use timeout-aware approach: send signal before cancelling, matching Control-C behavior
            try:
                # Create a timeout task that sends SIGINT (matching Control-C) when timeout is reached
                async def send_timeout_signal():
                    await asyncio.sleep(timeout)
                    # Timeout reached - send SIGINT to process (matching Control-C exactly)
                    if process and process.pid:
                        try:
                            # On Windows, subprocesses launched via bash.exe are ALWAYS Cygwin processes
                            # So we should use Cygwin kill methods, not Windows methods
                            if os.name == 'nt' or IS_CYGWIN:
                                    # Cygwin: map Windows PID to Cygwin PID, then use kill command
                                    # Send to parent first, then get all children and send to them too
                                    # This ensures all processes in the tree receive the signal
                                    try:
                                        # Map parent Windows PID to Cygwin PID
                                        cygwin_pid = await get_cygwin_pid(process.pid)
                                        if cygwin_pid:
                                            # Send SIGINT to parent process
                                            logger.warning(f"[TIMEOUT SIGNAL] Platform: Cygwin | Method: 'kill -INT' command | Windows PID: {process.pid} -> Cygwin PID: {cygwin_pid}")
                                            kill_proc = await asyncio.create_subprocess_exec(
                                                'kill', '-INT', str(cygwin_pid),
                                                stdout=asyncio.subprocess.DEVNULL,
                                                stderr=asyncio.subprocess.DEVNULL
                                            )
                                            await asyncio.wait_for(kill_proc.wait(), timeout=2.0)
                                            logger.debug(f"Timeout reached ({timeout}s), sent SIGINT to parent process (Windows PID {process.pid}, Cygwin PID {cygwin_pid}) via Cygwin kill command")
                                            
                                            # Also send SIGINT to all child processes (they might not inherit the signal)
                                            if PSUTIL_AVAILABLE:
                                                try:
                                                    parent_proc = psutil.Process(process.pid)
                                                    children = parent_proc.children(recursive=True)
                                                    if children:
                                                        logger.info(f"Sending SIGINT to {len(children)} child process(es) via Cygwin kill command...")
                                                        for child in children:
                                                            try:
                                                                child_cygwin_pid = await get_cygwin_pid(child.pid)
                                                                if child_cygwin_pid:
                                                                    logger.warning(f"[TIMEOUT SIGNAL] Platform: Cygwin | Method: 'kill -INT' command | Child Windows PID: {child.pid} -> Cygwin PID: {child_cygwin_pid}")
                                                                    child_kill_proc = await asyncio.create_subprocess_exec(
                                                                        'kill', '-INT', str(child_cygwin_pid),
                                                                        stdout=asyncio.subprocess.DEVNULL,
                                                                        stderr=asyncio.subprocess.DEVNULL
                                                                    )
                                                                    await asyncio.wait_for(child_kill_proc.wait(), timeout=1.0)
                                                                    logger.debug(f"Sent SIGINT to child process (Windows PID {child.pid}, Cygwin PID {child_cygwin_pid}) via Cygwin kill command")
                                                                else:
                                                                    logger.warning(f"Could not map child Windows PID {child.pid} to Cygwin PID, skipping")
                                                            except (asyncio.TimeoutError, FileNotFoundError, ProcessLookupError) as child_err:
                                                                # Child might have already exited
                                                                logger.debug(f"Error sending SIGINT to child process {child.pid}: {child_err}")
                                                                pass
                                                except (psutil.NoSuchProcess, psutil.AccessDenied):
                                                    # Parent or children might have already exited
                                                    pass
                                            
                                            logger.debug(f"Timeout reached ({timeout}s), sent SIGINT to process tree starting at Windows PID {process.pid} (Cygwin PID {cygwin_pid}) via Cygwin kill command (matching Control-C)")
                                        else:
                                            # Could not map PID, fallback to os.kill
                                            logger.warning(f"[TIMEOUT SIGNAL] Platform: Cygwin | Method: os.kill() (fallback - PID mapping failed) | Windows PID: {process.pid}")
                                            os.kill(process.pid, signal.SIGINT)
                                    except (asyncio.TimeoutError, FileNotFoundError, ProcessLookupError) as kill_err:
                                        # Fallback to os.kill if kill command fails
                                        logger.warning(f"[TIMEOUT SIGNAL] Platform: Cygwin (Windows subprocess) | Method: os.kill() (fallback - kill command failed: {kill_err}) | Windows PID: {process.pid}")
                                        os.kill(process.pid, signal.SIGINT)
                            else:
                                # Linux: try process group first, fallback to process
                                try:
                                    pgid = os.getpgid(process.pid)
                                    logger.warning(f"[TIMEOUT SIGNAL] Platform: Linux | Method: os.killpg() (SIGINT to process group) | PID: {process.pid} | Process Group: {pgid}")
                                    os.killpg(pgid, signal.SIGINT)
                                except (ProcessLookupError, OSError) as pg_err:
                                    # Fallback: send to process directly if process group fails
                                    logger.warning(f"[TIMEOUT SIGNAL] Platform: Linux | Method: os.kill() (SIGINT to process, fallback - process group failed: {pg_err}) | PID: {process.pid}")
                                    os.kill(process.pid, signal.SIGINT)
                        except (ProcessLookupError, psutil.NoSuchProcess, psutil.AccessDenied) as sig_err:
                            logger.debug(f"Process already gone or cannot send signal: {sig_err}")
                        except Exception as sig_err:
                            logger.warning(f"Error sending timeout signal: {sig_err}")
                
                # Start both tasks concurrently
                timeout_task = asyncio.create_task(send_timeout_signal())
                read_task = asyncio.create_task(read_streams())
                
                # Wait for either to complete first
                done, pending = await asyncio.wait(
                    [timeout_task, read_task],
                    return_when=asyncio.FIRST_COMPLETED
                )
                
                # Determine what happened
                if timeout_task in done:
                    # Timeout occurred - signal already sent
                    timed_out = True
                    interrupt_reason = ("timeout", f"timed out after {timeout} seconds")
                    logger.warning(f"Script execution {interrupt_reason[1]}, signal sent, waiting for cleanup handlers and process exit...")
                    
                    # Signal was sent (SIGINT matching Control-C), now wait for process to handle it and exit
                    # read_task is still running and will complete when process exits
                    # Use the same helper function for both timeout and interrupt
                    stdout_bytes, stderr_bytes = await _wait_for_read_task_and_collect_output(
                        read_task, chunks_stdout, chunks_stderr, signal_type="timeout"
                    )
                elif read_task in done:
                    # Normal completion - process finished before timeout
                    timed_out = False
                    # Cancel timeout task since we don't need it anymore
                    timeout_task.cancel()
                    try:
                        await timeout_task
                    except (asyncio.CancelledError, KeyboardInterrupt):
                        pass
                    
                    # Collect the data (read_task already completed)
                    stdout_bytes = b''.join(chunks_stdout)
                    stderr_bytes = b''.join(chunks_stderr)
                
            except KeyboardInterrupt as e:
                # KeyboardInterrupt occurred (user pressed Control-C)
                # On Windows, subprocesses launched via bash.exe are ALWAYS Cygwin processes
                # So we should use Cygwin kill methods, not Windows methods
                # Send SIGINT to match Control-C behavior, but use shorter wait times since user wants quick shutdown
                timed_out = True
                interrupt_reason = ("interrupt", "interrupted by KeyboardInterrupt (Ctrl+C)")
                logger.warning(f"Script execution {interrupt_reason[1]}, sending signal...")
                
                # Cancel timeout task if it's still running
                if 'timeout_task' in locals():
                    timeout_task.cancel()
                    try:
                        await timeout_task
                    except (asyncio.CancelledError, KeyboardInterrupt):
                        pass
                
                # Send SIGINT to process (matching Control-C) - same as timeout but with shorter wait
                if process and process.pid:
                    try:
                        if os.name == 'nt' or IS_CYGWIN:
                            # Cygwin: map Windows PID to Cygwin PID, then use kill command
                            cygwin_pid = await get_cygwin_pid(process.pid)
                            if cygwin_pid:
                                try:
                                    logger.warning(f"[INTERRUPT SIGNAL] Platform: Cygwin (Windows subprocess) | Method: 'kill -INT' command | Windows PID: {process.pid} -> Cygwin PID: {cygwin_pid}")
                                    kill_proc = await asyncio.create_subprocess_exec(
                                        'kill', '-INT', str(cygwin_pid),
                                        stdout=asyncio.subprocess.DEVNULL,
                                        stderr=asyncio.subprocess.DEVNULL
                                    )
                                    await asyncio.wait_for(kill_proc.wait(), timeout=1.0)
                                    logger.debug(f"Sent SIGINT to process (Windows PID {process.pid}, Cygwin PID {cygwin_pid}) via Cygwin kill command")
                                except (asyncio.TimeoutError, FileNotFoundError, ProcessLookupError) as kill_err:
                                    # Fallback to os.kill if kill command fails
                                    logger.warning(f"[INTERRUPT SIGNAL] Platform: Cygwin (Windows subprocess) | Method: os.kill() (fallback - kill command failed: {kill_err}) | Windows PID: {process.pid}")
                                    try:
                                        os.kill(process.pid, signal.SIGINT)
                                    except (ProcessLookupError, OSError):
                                        pass
                            else:
                                # Could not map PID, fallback to os.kill
                                logger.warning(f"[INTERRUPT SIGNAL] Platform: Cygwin (Windows subprocess) | Method: os.kill() (fallback - PID mapping failed) | Windows PID: {process.pid}")
                                try:
                                    os.kill(process.pid, signal.SIGINT)
                                except (ProcessLookupError, OSError):
                                    pass
                        else:
                            # Linux: try process group first, fallback to process
                            try:
                                pgid = os.getpgid(process.pid)
                                logger.warning(f"[INTERRUPT SIGNAL] Platform: Linux | Method: os.killpg() (SIGINT to process group) | PID: {process.pid} | Process Group: {pgid}")
                                os.killpg(pgid, signal.SIGINT)
                            except (ProcessLookupError, OSError) as pg_err:
                                # Fallback: send to process directly if process group fails
                                logger.warning(f"[INTERRUPT SIGNAL] Platform: Linux | Method: os.kill() (SIGINT to process, fallback - process group failed: {pg_err}) | PID: {process.pid}")
                                try:
                                    os.kill(process.pid, signal.SIGINT)
                                except (ProcessLookupError, OSError):
                                    pass
                    except (ProcessLookupError, OSError) as sig_err:
                        logger.debug(f"Process already gone or cannot send signal: {sig_err}")
                
                logger.warning(f"Script execution {interrupt_reason[1]}, signal sent, waiting for cleanup handlers and process exit (short timeout for quick shutdown)...")
                
                # Wait for read_task to complete (use shorter timeout for interrupts)
                # read_task should still be running and will complete when process exits
                if 'read_task' in locals():
                    stdout_bytes, stderr_bytes = await _wait_for_read_task_and_collect_output(
                        read_task, chunks_stdout, chunks_stderr, signal_type="interrupt"
                    )
                else:
                    # read_task wasn't created yet, just collect what we have
                    stdout_bytes = b''.join(chunks_stdout)
                    stderr_bytes = b''.join(chunks_stderr)
            
            # If timed out/interrupted and process is still running, force kill and read remaining output
            # This is the same for both timeout and KeyboardInterrupt
            if timed_out and process and process.returncode is None:
                # Process didn't exit after signal, need to force kill and read remaining output
                logger.debug("Process still running after signal and wait, force killing and reading remaining output...")
                stdout_bytes, stderr_bytes = await _kill_process_and_read_remaining_output(
                    process, stdout_bytes, stderr_bytes
                )
        else:
            # No timeout - use standard communicate
            stdout_bytes, stderr_bytes = await process.communicate()
        
        # Decode bytes to strings
        stdout = stdout_bytes.decode('utf-8', errors='replace') if stdout_bytes else ''
        stderr = stderr_bytes.decode('utf-8', errors='replace') if stderr_bytes else ''
        
        # Sanitize output immediately after decoding to prevent any control characters
        # from corrupting logs or terminal output - this must happen before any logging
        stdout = sanitize_subprocess_output(stdout)
        stderr = sanitize_subprocess_output(stderr)
        
        # Remove process from tracking when it finishes
        if process and process.pid and process.pid in running_processes:
            del running_processes[process.pid]
            logger.debug(f"Removed process PID {process.pid} from tracking")
        
        # Close process streams to avoid unclosed transport warnings
        # This is especially important on Windows with ProactorEventLoop
        # We MUST close streams before the event loop closes to avoid "Event loop is closed" errors
        # Note: Stream closing will also be handled in finally block to ensure it always happens
        try:
            if process:
                if process.stdout:
                    try:
                        process.stdout.close()
                    except (RuntimeError, OSError, ValueError) as close_err:
                        logger.debug(f"Error closing stdout stream: {close_err}")
                if process.stderr:
                    try:
                        process.stderr.close()
                    except (RuntimeError, OSError, ValueError) as close_err:
                        logger.debug(f"Error closing stderr stream: {close_err}")
        except Exception as e:
            logger.debug(f"Error closing process streams: {e}")
        
        if timed_out:
            # Determine the appropriate error message based on the reason
            # Use the stored interrupt reason from the exception handler
            if interrupt_reason:
                reason_type, reason_text = interrupt_reason
                if reason_type == "timeout":
                    error_msg = f"Script execution timed out after {timeout} seconds"
                    output_label = "before timeout"
                elif reason_type == "interrupt":
                    error_msg = "Script execution was interrupted (Ctrl+C)"
                    output_label = "before interruption"
                else:
                    error_msg = "Script execution was cancelled"
                    output_label = "before cancellation"
            else:
                # Fallback if reason wasn't set (shouldn't happen, but just in case)
                error_msg = f"Script execution timed out after {timeout} seconds"
                output_label = "before timeout"
            
            # Sanitize output before using it (in case it wasn't sanitized yet)
            stdout = sanitize_subprocess_output(stdout) if stdout else ''
            stderr = sanitize_subprocess_output(stderr) if stderr else ''
            
            # Prepend error message to stderr, but keep any captured output
            if stderr:
                # Check if error message is already in stderr (from cleanup handlers)
                if error_msg.lower() not in stderr.lower():
                    stderr = f"{error_msg}\n\n--- Partial output {output_label} ---\n{stderr}"
            else:
                stderr = error_msg
            if stdout:
                stderr += f"\n\n--- Partial stdout {output_label} ---\n{stdout}"
            
            return {
                'returncode': -1,
                'stdout': stdout,
                'stderr': stderr,
                'success': False,
                'timeout': True
            }
        
        # Log captured output for debugging (output is already sanitized)
        logger.debug(f"Script returncode: {process.returncode}")
        logger.debug(f"Script stdout length: {len(stdout)} bytes")
        logger.debug(f"Script stderr length: {len(stderr)} bytes")
        if stdout:
            logger.debug(f"Script stdout (first 500 chars): {stdout[:500]}")
        if stderr:
            logger.debug(f"Script stderr (first 500 chars): {stderr[:500]}")
        
        return {
            'returncode': process.returncode,
            'stdout': stdout,  # Already sanitized
            'stderr': stderr,  # Already sanitized
            'success': process.returncode == 0
        }
    except Exception as e:
        logger.exception(f"Exception while executing script: {e}")
        # Make sure to kill the process tree if it's still running
        if process and process.returncode is None:
            try:
                if process.pid:
                    await kill_process_tree(process.pid, timeout=5.0)
                    # Remove from tracking
                    if process.pid in running_processes:
                        del running_processes[process.pid]
                else:
                    # Fallback if PID not available
                    process.kill()
                    await process.wait()
            except Exception as e:
                logger.debug(f"Error cleaning up process: {e}")
        # Ensure streams are closed even on exception
        try:
            if process:
                if process.stdout:
                    try:
                        process.stdout.close()
                    except (RuntimeError, OSError, ValueError):
                        pass
                if process.stderr:
                    try:
                        process.stderr.close()
                    except (RuntimeError, OSError, ValueError):
                        pass
        except Exception:
            pass
        return {
            'returncode': -1,
            'stdout': '',
            'stderr': str(e),
            'success': False
        }
    finally:
        # Always ensure streams are closed, even if function returns early or raises
        # This is critical on Windows with ProactorEventLoop to avoid "Event loop is closed" errors
        # On Windows ProactorEventLoop, close() schedules async close operations
        # If the event loop is already closing, these operations will fail with RuntimeError
        # We catch and ignore these errors since we're just cleaning up resources
        if 'process' in locals() and process:
            try:
                # Close stdout stream
                if process.stdout:
                    try:
                        # On Windows ProactorEventLoop, close() schedules close on event loop
                        # This will fail gracefully if event loop is already closing
                        process.stdout.close()
                    except RuntimeError as close_err:
                        # Event loop is closed - this is expected when shutting down
                        # The stream will be cleaned up by the garbage collector
                        if "Event loop is closed" not in str(close_err):
                            logger.debug(f"Error closing stdout in finally: {close_err}")
                    except (OSError, ValueError, AttributeError) as close_err:
                        logger.debug(f"Error closing stdout in finally: {close_err}")
                        pass  # Stream might already be closed
                # Close stderr stream
                if process.stderr:
                    try:
                        process.stderr.close()
                    except RuntimeError as close_err:
                        # Event loop is closed - this is expected when shutting down
                        # The stream will be cleaned up by the garbage collector
                        if "Event loop is closed" not in str(close_err):
                            logger.debug(f"Error closing stderr in finally: {close_err}")
                    except (OSError, ValueError, AttributeError) as close_err:
                        logger.debug(f"Error closing stderr in finally: {close_err}")
                        pass  # Stream might already be closed
            except Exception as cleanup_err:
                # Ignore all errors in finally block - we're just trying to clean up
                # Any errors here are non-fatal since we're just cleaning up resources
                pass

def get_split_group_key(message, caption: str) -> Optional[tuple]:
    """Create a key for tracking split media groups.
    
    Split groups have the same caption and come from the same chat.
    Returns (chat_id, caption_hash) tuple, or None if caption is empty.
    """
    if not caption or not caption.strip():
        return None
    
    chat_id = message.chat.id if message.chat else None
    if chat_id is None:
        return None
    
    # Use a hash of the caption for the key (normalize whitespace)
    caption_normalized = caption.strip()
    caption_hash = hash(caption_normalized)
    
    return (chat_id, caption_hash)


async def process_split_groups(split_key: tuple, context: ContextTypes.DEFAULT_TYPE) -> None:
    """Process all media groups in a split group together.
    
    Args:
        split_key: The split group key (chat_id, caption_hash)
        context: Bot context
    """
    if split_key not in pending_split_groups:
        return
    
    split_data = pending_split_groups[split_key]
    if split_data.get('processed', False):
        return
    
    split_data['processed'] = True
    groups = split_data.get('groups', [])
    channel_config = split_data.get('channel_config')
    
    if not groups:
        logger.warning(f"Split group {split_key} has no groups, skipping")
        del pending_split_groups[split_key]
        return
    
    # Combine all messages from all groups
    all_messages = []
    for group in groups:
        all_messages.extend(group['messages'])
    
    if not all_messages:
        logger.warning(f"Split group {split_key} has no messages, skipping")
        del pending_split_groups[split_key]
        return
    
    logger.info(f"Processing split group {split_key} with {len(groups)} group(s) and {len(all_messages)} total message(s)")
    
    # Process all messages as a single combined media group
    # Use the first message's media_group_id for logging purposes
    first_media_group_id = groups[0].get('media_group_id', 'split_combined')
    await process_media_group(first_media_group_id, all_messages, context, channel_config, is_split_group=True)
    
    # Clean up
    del pending_split_groups[split_key]


async def process_media_group(media_group_id: str, messages: List, context: ContextTypes.DEFAULT_TYPE, channel_config: dict = None, is_split_group: bool = False) -> None:
    """Process all messages in a media group together.
    
    Args:
        media_group_id: The media group ID
        messages: List of messages in the group
        context: Bot context
        channel_config: Optional channel configuration dict (if None, will be detected from messages)
        is_split_group: If True, this is already a combined split group and should be processed immediately.
                        If False, may check for split groups (groups with same caption split across multiple media_group_ids).
                        Telegram splits large media groups based on total size, so groups with the same caption are matched
                        regardless of the number of files in each group.
    """
    if not messages:
        return
    
    # Get config from context
    config = context.bot_data.get('config')
    if not config:
        logger.error("Configuration not found in bot_data")
        return
    
    # Use the first message for channel/profile detection if channel_config not provided
    first_message = messages[0]
    
    # If channel_config not provided, detect it from the first message
    if channel_config is None:
        # Check if message is from the owner (same logic as handle_message)
        is_owner = False
        
        if first_message.from_user:
            is_owner = (first_message.from_user.id == config['owner_id'])
            if not is_owner:
                logger.info(f"Media group from non-owner user {first_message.from_user.id}, ignoring")
                return
            
            chat_id = first_message.chat.id if first_message.chat.id else None
            chat_username = first_message.chat.username if first_message.chat.username else None
            channel_config = find_channel_config(config, chat_id=chat_id, chat_username=chat_username)
        elif first_message.sender_chat:
            sender_chat_id = first_message.sender_chat.id
            sender_chat_username = first_message.sender_chat.username if first_message.sender_chat.username else None
            chat_id = first_message.chat.id if first_message.chat.id else None
            chat_username = first_message.chat.username if first_message.chat.username else None
            
            channel_config = find_channel_config(config, chat_id=sender_chat_id, chat_username=sender_chat_username)
            if not channel_config:
                channel_config = find_channel_config(config, chat_id=chat_id, chat_username=chat_username)
            
            if channel_config:
                is_owner = True
            else:
                logger.info(f"Media group from channel with no matching config, ignoring")
                return
        else:
            logger.info("Media group has no from_user or sender_chat, ignoring")
            return
        
        # Require channel configuration
        if not channel_config:
            logger.info("No channel configuration found for media group, ignoring")
            return
    
    profile_name = channel_config.get('profile_name')
    if not profile_name:
        logger.error(f"Channel config found but profile_name is missing, ignoring")
        return
    
    # Collect caption from the first message (Telegram usually puts caption on first message)
    text = first_message.caption or first_message.text or ""
    
    logger.info(f"Processing media group {media_group_id} with {len(messages)} message(s)")
    
    # Check for split groups: if we have a caption and this is not already a split group,
    # check if this might be part of a split group or start a new split group tracker
    # Telegram splits large groups based on total size, not file count, so we match by caption only
    if not is_split_group and text and text.strip():
        split_key = get_split_group_key(first_message, text)
        if split_key:
            # Check if there's already a pending split group with this key
            if split_key in pending_split_groups:
                split_data = pending_split_groups[split_key]
                if not split_data.get('processed', False):
                    # Add this group to the split group
                    split_data['groups'].append({
                        'media_group_id': media_group_id,
                        'messages': messages
                    })
                    logger.info(f"Added media group {media_group_id} to split group {split_key} (total groups: {len(split_data['groups'])})")
                    
                    # Cancel previous timeout and create new one (reset timeout)
                    if 'task' in split_data and not split_data['task'].done():
                        try:
                            split_data['task'].cancel()
                        except Exception as e:
                            logger.warning(f"Error cancelling split group timeout task: {e}")
                    
                    # Create new timeout task
                    async def process_split_after_timeout():
                        try:
                            await asyncio.sleep(SPLIT_GROUP_TIMEOUT)
                            if split_key in pending_split_groups:
                                await process_split_groups(split_key, context)
                        except asyncio.CancelledError:
                            pass
                        except Exception as e:
                            logger.exception(f"Error in split group timeout task: {e}")
                            if split_key in pending_split_groups:
                                del pending_split_groups[split_key]
                    
                    split_data['task'] = asyncio.create_task(process_split_after_timeout())
                    # Return early - don't download yet, wait for more groups
                    return
            else:
                # Create new split group tracker
                logger.info(f"Starting new split group {split_key} with media group {media_group_id} (caption detected)")
                
                async def process_split_after_timeout():
                    try:
                        await asyncio.sleep(SPLIT_GROUP_TIMEOUT)
                        if split_key in pending_split_groups:
                            await process_split_groups(split_key, context)
                    except asyncio.CancelledError:
                        pass
                    except Exception as e:
                        logger.exception(f"Error in split group timeout task: {e}")
                        if split_key in pending_split_groups:
                            del pending_split_groups[split_key]
                
                pending_split_groups[split_key] = {
                    'groups': [{
                        'media_group_id': media_group_id,
                        'messages': messages
                    }],
                    'task': asyncio.create_task(process_split_after_timeout()),
                    'processed': False,
                    'channel_config': channel_config
                }
                # Return early - don't download yet, wait for more groups
                return
    
    # Collect all media files from all messages in the group (download now)
    media_files = []
    for msg in messages:
        # Download media from each message
        if msg.photo:
            largest_photo = max(msg.photo, key=lambda p: p.file_size if p.file_size else 0)
            logger.info(f"Downloading photo from media group message...")
            temp_file = await download_media_file(context.bot, largest_photo, 'jpg')
            if temp_file:
                media_files.append(temp_file)
        elif msg.video:
            logger.info(f"Downloading video from media group message...")
            temp_file = await download_media_file(context.bot, msg.video, 'mp4')
            if temp_file:
                media_files.append(temp_file)
        elif msg.document:
            if msg.document.mime_type:
                if msg.document.mime_type.startswith('image/'):
                    ext = None
                    if msg.document.file_name:
                        ext = Path(msg.document.file_name).suffix.lstrip('.')
                    if not ext:
                        ext = msg.document.mime_type.split('/')[-1]
                    logger.info(f"Downloading image document from media group message...")
                    temp_file = await download_media_file(context.bot, msg.document, ext)
                    if temp_file:
                        media_files.append(temp_file)
                elif msg.document.mime_type.startswith('video/'):
                    ext = None
                    if msg.document.file_name:
                        ext = Path(msg.document.file_name).suffix.lstrip('.')
                    if not ext:
                        ext = msg.document.mime_type.split('/')[-1]
                    logger.info(f"Downloading video document from media group message...")
                    temp_file = await download_media_file(context.bot, msg.document, ext)
                    if temp_file:
                        media_files.append(temp_file)
    
    if not media_files:
        logger.warning(f"No media files collected from media group {media_group_id}")
        return
    
    # Try to send acknowledgment
    status_msg = None
    try:
        status_msg = await send_message_with_retry(
            first_message,
            f"Processing media group with {len(media_files)} file(s)..."
        )
        if status_msg is None:
            logger.warning("Could not send status message for media group, continuing without it")
    except Exception as e:
        logger.warning(f"Failed to send status message for media group: {e}, continuing without it")
    
    try:
        # Get disable_cookies_for_sites from channel config or global config
        # Use 'in' check to handle empty lists correctly (empty list means "don't disable for this channel")
        if 'disable_cookies_for_sites' in channel_config:
            disable_cookies_sites = channel_config.get('disable_cookies_for_sites')
        else:
            disable_cookies_sites = config.get('disable_cookies_for_sites')
        
        # Build command with all media files
        cmd = build_command(
            profile_name,
            config['script_path'],
            media_files,  # Pass all file paths
            text,  # Use caption/text as description
            config.get('use_firefox', True),
            config.get('cookies_file'),
            config,
            channel_config.get('nsfw', False),  # Get NSFW setting from channel config
            disable_cookies_sites  # Get disable cookies setting from channel or global config
        )
        
        # Execute script with timeout
        timeout = config.get('script_timeout', 360)
        result = await execute_script(cmd, timeout=timeout)
        
        # Clean up temporary files
        for temp_file in media_files:
            try:
                if os.path.exists(temp_file):
                    os.unlink(temp_file)
                    logger.debug(f"Cleaned up temporary file: {temp_file}")
            except Exception as e:
                logger.warning(f"Failed to clean up temporary file {temp_file}: {e}")
        
        # Format response (same as single media processing)
        if result['success']:
            logger.info(f"Script execution successful. stdout length: {len(result['stdout'])}, stderr length: {len(result['stderr'])}")
            if result['stdout']:
                sanitized_stdout = sanitize_subprocess_output(result['stdout'])
                logger.info(f"Script stdout:\n{sanitized_stdout}")
            if result['stderr']:
                sanitized_stderr = sanitize_subprocess_output(result['stderr'])
                logger.info(f"Script stderr:\n{sanitized_stderr}")
            
            event_id = None
            nevent = None
            
            if result['stdout']:
                event_id = extract_event_id(result['stdout'])
                if event_id:
                    logger.info(f"Extracted event ID from stdout: {event_id}")
            
            if not event_id and result['stderr']:
                event_id = extract_event_id(result['stderr'])
                if event_id:
                    logger.info(f"Extracted event ID from stderr: {event_id}")
            
            if event_id:
                nevent = await encode_to_nevent(event_id)
                logger.info(f"Encoded to nevent: {nevent}")
            else:
                logger.warning(f"Could not extract event ID from output for media group")
            
            if nevent:
                if config.get('nostr_client_url'):
                    client_url_template = config['nostr_client_url']
                    if '{nevent}' in client_url_template:
                        client_url = client_url_template.format(nevent=nevent)
                    else:
                        if client_url_template.endswith('/'):
                            client_url = f"{client_url_template}e/{nevent}"
                        else:
                            client_url = f"{client_url_template}/e/{nevent}"
                    
                    response_msg = f"✅ [View on Nostr]({client_url})\n\n`{nevent}`"
                    if status_msg:
                        await send_message_with_retry(status_msg, response_msg, edit_text=True, parse_mode='Markdown')
                    else:
                        await send_message_with_retry(first_message, response_msg, parse_mode='Markdown')
                    logger.info(f"Successfully processed media group, nevent: {nevent}, client_url: {client_url}")
                else:
                    if status_msg:
                        await send_message_with_retry(status_msg, nevent, edit_text=True)
                    else:
                        await send_message_with_retry(first_message, nevent)
                    logger.info(f"Successfully processed media group, nevent: {nevent}")
            else:
                logger.warning(f"Could not extract event ID from output for media group")
                success_msg = f"✅ Successfully processed media group with {len(media_files)} file(s)"
                if event_id:
                    success_msg += f"\nEvent ID: {event_id} (could not encode to nevent)"
                if status_msg:
                    await send_message_with_retry(status_msg, success_msg, edit_text=True)
                else:
                    await send_message_with_retry(first_message, success_msg)
        else:
            # Check for timeout first
            if result.get('timeout'):
                timeout_seconds = config.get('script_timeout', 360)
                error_parts = [f"⏱️ Script execution timed out after {timeout_seconds} seconds\n\nThe request took too long and was cancelled. This may happen with rate-limited sites."]
                
                # Include any captured output before timeout
                if result.get('stderr'):
                    error_parts.append(result['stderr'])
                if result.get('stdout') and 'Partial stdout' not in (result.get('stderr') or ''):
                    error_parts.append(f"\n--- Partial stdout before timeout ---\n{result['stdout']}")
                
                error_msg = "\n\n".join(error_parts)
                
                # Truncate if too long (Telegram limit)
                MAX_ERROR_LENGTH = 3500
                if len(error_msg) > MAX_ERROR_LENGTH:
                    truncated_msg = error_msg[-MAX_ERROR_LENGTH:]
                    first_newline = truncated_msg.find('\n')
                    if first_newline > 0 and first_newline < MAX_ERROR_LENGTH * 0.2:
                        truncated_msg = truncated_msg[first_newline+1:]
                    error_display = f"⏱️ Script execution timed out after {timeout_seconds} seconds\n\n... (truncated, full error in logs)\n\n{truncated_msg}"
                else:
                    error_display = error_msg
            else:
                error_parts = []
                if result['stderr']:
                    error_parts.append(f"Error:\n{result['stderr']}")
                if result['stdout']:
                    error_parts.append(f"Output:\n{result['stdout']}")
                
                error_msg = "\n\n".join(error_parts) if error_parts else "Unknown error"
                
                MAX_ERROR_LENGTH = 3500
                if len(error_msg) > MAX_ERROR_LENGTH:
                    truncated_msg = error_msg[-MAX_ERROR_LENGTH:]
                    first_newline = truncated_msg.find('\n')
                    if first_newline > 0 and first_newline < MAX_ERROR_LENGTH * 0.2:
                        truncated_msg = truncated_msg[first_newline+1:]
                    error_display = f"❌ Error processing media group\n\n... (truncated, full error in logs)\n\n{truncated_msg}"
                else:
                    error_display = f"❌ Error processing media group\n\n{error_msg}"
            
            if status_msg:
                await send_message_with_retry(status_msg, error_display, edit_text=True)
            else:
                await send_message_with_retry(first_message, error_display)
            logger.error(f"Error processing media group")
            sanitized_stderr = sanitize_subprocess_output(result['stderr'])
            sanitized_stdout = sanitize_subprocess_output(result['stdout'])
            logger.error(f"stderr: {sanitized_stderr}")
            logger.error(f"stdout: {sanitized_stdout}")
    except Exception as e:
        logger.exception(f"Exception while processing media group: {e}")
        try:
            await send_message_with_retry(first_message, f"❌ Exception occurred: {str(e)}")
        except Exception as send_error:
            logger.error(f"Failed to send error message: {send_error}")
        for temp_file in media_files:
            try:
                if os.path.exists(temp_file):
                    os.unlink(temp_file)
            except Exception:
                pass


async def send_message_with_retry(message, text, max_retries=3, retry_delay=1.0, edit_text=False, **kwargs):
    """Send a message with retry logic for timeout and network errors.
    
    Args:
        message: The message object to reply to or edit
        text: The text to send
        max_retries: Maximum number of retry attempts (default: 3)
        retry_delay: Initial delay between retries in seconds (default: 1.0)
        edit_text: If True, edit the existing message; if False, send a new message
        **kwargs: Additional arguments to pass to reply_text/edit_text
    
    Returns:
        The sent message object, or None if all retries failed
    """
    last_exception = None
    for attempt in range(max_retries):
        try:
            if edit_text:
                # Editing existing message
                return await message.edit_text(text, **kwargs)
            else:
                # Sending new message
                return await message.reply_text(text, **kwargs)
        except (TimedOut, NetworkError) as e:
            last_exception = e
            if attempt < max_retries - 1:
                wait_time = retry_delay * (2 ** attempt)  # Exponential backoff
                logger.warning(f"Message send attempt {attempt + 1} failed with {type(e).__name__}, retrying in {wait_time}s...")
                await asyncio.sleep(wait_time)
            else:
                logger.error(f"Failed to send message after {max_retries} attempts: {e}")
        except Exception as e:
            # For non-network errors, don't retry
            logger.error(f"Non-retryable error sending message: {e}")
            raise
    
    # If we get here, all retries failed
    logger.error(f"Could not send message after {max_retries} attempts. Last error: {last_exception}")
    return None


async def handle_message(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """Handle incoming messages and process links from the owner."""
    # Handle both regular messages and channel posts
    message = update.message or update.channel_post
    edited_message = update.edited_message or update.edited_channel_post
    
    # Use edited message if available, otherwise use regular message
    message = edited_message or message
    
    if not message:
        # Not a message update, ignore
        return
    
    # Get config from context
    config = context.bot_data.get('config')
    if not config:
        logger.error("Configuration not found in bot_data")
        return
    
    # Check if message is from the owner
    # For regular messages: check from_user.id matches owner_id
    # For channel posts: check if sender_chat matches a configured channel
    is_owner = False
    channel_config = None
    
    if message.from_user:
        # Regular message - check if user ID matches owner_id
        is_owner = (message.from_user.id == config['owner_id'])
        if not is_owner:
            logger.info(f"Message from non-owner user {message.from_user.id}, ignoring")
            return
        
        # Check for /reload command in direct messages (private chats)
        if message.chat.type == 'private':
            text = message.text or message.caption or ""
            if text.strip().startswith('/reload'):
                # Reload configuration
                config_path = context.bot_data.get('config_path', CONFIG_FILE)
                use_firefox = context.bot_data.get('use_firefox', True)
                
                try:
                    logger.info(f"Reloading configuration from {config_path}")
                    cookies_file = context.bot_data.get('cookies_file')
                    new_config = load_config(config_path, use_firefox=use_firefox, cookies_file=cookies_file)
                    
                    # Validate new config
                    if not new_config.get('bot_token'):
                        await message.reply_text("❌ Error: bot_token is missing in reloaded configuration")
                        return
                    
                    if new_config['owner_id'] == 0:
                        await message.reply_text("❌ Error: owner_id is missing in reloaded configuration")
                        return
                    
                    # Update bot_data with new config
                    context.bot_data['config'] = new_config
                    
                    # Count channels
                    channels_count = len(new_config.get('channels', {}))
                    
                    # Build status message
                    status_parts = [
                        f"✅ Configuration reloaded successfully!",
                        f"",
                        f"Channels: {channels_count}",
                        f"Script path: {new_config['script_path']}",
                    ]
                    if new_config.get('cookies_file'):
                        status_parts.append(f"Cookies file: {new_config['cookies_file']}")
                    else:
                        status_parts.append(f"Use Firefox: {new_config.get('use_firefox', True)}")
                    
                    await message.reply_text("\n".join(status_parts))
                    logger.info(f"Configuration reloaded successfully. Channels: {channels_count}")
                except Exception as e:
                    error_msg = f"❌ Failed to reload configuration: {str(e)}"
                    logger.exception(f"Error reloading configuration: {e}")
                    await message.reply_text(error_msg)
            return
        # For regular messages, try to find channel config based on chat
        chat_id = message.chat.id if message.chat.id else None
        chat_username = message.chat.username if message.chat.username else None
        channel_config = find_channel_config(config, chat_id=chat_id, chat_username=chat_username)
    elif message.sender_chat:
        # Channel post - find matching channel config
        sender_chat_id = message.sender_chat.id
        sender_chat_username = message.sender_chat.username if message.sender_chat.username else None
        chat_id = message.chat.id if message.chat.id else None
        chat_username = message.chat.username if message.chat.username else None
        
        # Try to find channel config
        channel_config = find_channel_config(config, chat_id=sender_chat_id, chat_username=sender_chat_username)
        if not channel_config:
            channel_config = find_channel_config(config, chat_id=chat_id, chat_username=chat_username)
        
        if channel_config:
            is_owner = True
            logger.info(f"Channel post accepted: chat_id={sender_chat_id}, chat={chat_id}, found matching channel config")
        else:
            logger.info(f"Channel post from chat_id={sender_chat_id}, chat={chat_id}, no matching channel config found, ignoring")
            return
    else:
        logger.info("Message has no from_user or sender_chat, ignoring")
        return
    
    # Require channel configuration - no default profile
    if not channel_config:
        logger.info("No channel configuration found for this chat, ignoring")
        return
    
    # Get profile name from channel config (required, no default)
    profile_name = channel_config.get('profile_name')
    if not profile_name:
        logger.error(f"Channel config found but profile_name is missing, ignoring")
        return
    
    # Extract text from message
    text = message.text or message.caption or ""
    
    # Check if this message is part of a media group
    if message.media_group_id:
        media_group_id = message.media_group_id
        
        # Check if this media group is already being processed
        if media_group_id in pending_media_groups:
            group_data = pending_media_groups[media_group_id]
            if group_data.get('processed', False):
                # Already processed, ignore this message
                logger.info(f"Media group {media_group_id} already processed, ignoring duplicate message")
                return
            
            # Add this message to the group
            group_data['messages'].append(message)
            # Update channel_config if not already set (should already be set, but just in case)
            if 'channel_config' not in group_data:
                group_data['channel_config'] = channel_config
            logger.info(f"Added message to media group {media_group_id} (total: {len(group_data['messages'])})")
            
            # Cancel the previous timeout task and create a new one (reset timeout)
            if 'task' in group_data and not group_data['task'].done():
                try:
                    group_data['task'].cancel()
                except Exception as e:
                    logger.warning(f"Error cancelling timeout task: {e}")
            
            # Create new timeout task
            async def process_group_after_timeout():
                try:
                    await asyncio.sleep(MEDIA_GROUP_TIMEOUT)
                    if media_group_id in pending_media_groups:
                        group_data = pending_media_groups[media_group_id]
                        if not group_data.get('processed', False):
                            group_data['processed'] = True
                            # Get channel_config from stored group data
                            channel_cfg = group_data.get('channel_config')
                            await process_media_group(media_group_id, group_data['messages'], context, channel_cfg)
                            # Clean up
                            del pending_media_groups[media_group_id]
                except asyncio.CancelledError:
                    # Task was cancelled (new message arrived), this is expected
                    pass
                except Exception as e:
                    logger.exception(f"Error in media group timeout task: {e}")
                    # Clean up on error
                    if media_group_id in pending_media_groups:
                        del pending_media_groups[media_group_id]
            
            group_data['task'] = asyncio.create_task(process_group_after_timeout())
        else:
            # First message in a new media group
            logger.info(f"Starting new media group {media_group_id}")
            
            # Check if this might match an existing split group (same caption, same chat)
            # This allows us to track groups that arrive while another group is already waiting for split groups
            caption_text = message.caption or message.text or ""
            potential_split_key = get_split_group_key(message, caption_text)
            if potential_split_key and potential_split_key in pending_split_groups:
                split_data = pending_split_groups[potential_split_key]
                if not split_data.get('processed', False):
                    logger.info(f"New media group {media_group_id} matches pending split group {potential_split_key}, will be added when processed")
                    # Store a reference to the split group in the media group data for later use
                    # The actual addition will happen in process_media_group after timeout
            
            # Create timeout task
            async def process_group_after_timeout():
                try:
                    await asyncio.sleep(MEDIA_GROUP_TIMEOUT)
                    if media_group_id in pending_media_groups:
                        group_data = pending_media_groups[media_group_id]
                        if not group_data.get('processed', False):
                            group_data['processed'] = True
                            # Get channel_config from stored group data
                            channel_cfg = group_data.get('channel_config')
                            await process_media_group(media_group_id, group_data['messages'], context, channel_cfg)
                            # Clean up
                            del pending_media_groups[media_group_id]
                except asyncio.CancelledError:
                    # Task was cancelled (new message arrived), this is expected
                    pass
                except Exception as e:
                    logger.exception(f"Error in media group timeout task: {e}")
                    # Clean up on error
                    if media_group_id in pending_media_groups:
                        del pending_media_groups[media_group_id]
            
            pending_media_groups[media_group_id] = {
                'messages': [message],
                'task': asyncio.create_task(process_group_after_timeout()),
                'processed': False,
                'channel_config': channel_config  # Store channel_config for later use
            }
            logger.info(f"Created media group {media_group_id} with first message, waiting for more...")
        
        # Return early - processing will happen after timeout
        return
    
    # Not part of a media group - process immediately (existing logic)
    # Check for direct media uploads (photos or videos)
    media_files = []
    if message.photo:
        # Get the largest photo
        largest_photo = max(message.photo, key=lambda p: p.file_size if p.file_size else 0)
        logger.info(f"Received photo message, downloading...")
        temp_file = await download_media_file(context.bot, largest_photo, 'jpg')
        if temp_file:
            media_files.append(temp_file)
    elif message.video:
        logger.info(f"Received video message, downloading...")
        temp_file = await download_media_file(context.bot, message.video, 'mp4')
        if temp_file:
            media_files.append(temp_file)
    elif message.document:
        # Check if document is an image or video
        if message.document.mime_type:
            if message.document.mime_type.startswith('image/'):
                # Extract extension from mime type or filename
                ext = None
                if message.document.file_name:
                    ext = Path(message.document.file_name).suffix.lstrip('.')
                if not ext:
                    ext = message.document.mime_type.split('/')[-1]
                logger.info(f"Received image document, downloading...")
                temp_file = await download_media_file(context.bot, message.document, ext)
                if temp_file:
                    media_files.append(temp_file)
            elif message.document.mime_type.startswith('video/'):
                # Extract extension from mime type or filename
                ext = None
                if message.document.file_name:
                    ext = Path(message.document.file_name).suffix.lstrip('.')
                if not ext:
                    ext = message.document.mime_type.split('/')[-1]
                logger.info(f"Received video document, downloading...")
                temp_file = await download_media_file(context.bot, message.document, ext)
                if temp_file:
                    media_files.append(temp_file)
    
    # If we have media files, process them
    if media_files:
        # Try to send acknowledgment, but don't fail if it times out
        status_msg = None
        try:
            status_msg = await send_message_with_retry(
                message,
                f"Processing {len(media_files)} media file(s)..."
            )
            if status_msg is None:
                logger.warning("Could not send status message for media files, continuing without it")
        except Exception as e:
            logger.warning(f"Failed to send status message for media files: {e}, continuing without it")
        
        try:
            # Get disable_cookies_for_sites from channel config or global config
            # Use 'in' check to handle empty lists correctly (empty list means "don't disable for this channel")
            if 'disable_cookies_for_sites' in channel_config:
                disable_cookies_sites = channel_config.get('disable_cookies_for_sites')
            else:
                disable_cookies_sites = config.get('disable_cookies_for_sites')
            
            # Build command with local files
            cmd = build_command(
                profile_name,
                config['script_path'],
                media_files,  # Pass file paths instead of URLs
                text,  # Use full text as extra text (description)
                config.get('use_firefox', True),
                config.get('cookies_file'),
                config,
                channel_config.get('nsfw', False),  # Get NSFW setting from channel config
                disable_cookies_sites  # Get disable cookies setting from channel or global config
            )
            
            # Execute script with timeout
            timeout = config.get('script_timeout', 360)
            result = await execute_script(cmd, timeout=timeout)
            
            # Clean up temporary files
            for temp_file in media_files:
                try:
                    if os.path.exists(temp_file):
                        os.unlink(temp_file)
                        logger.debug(f"Cleaned up temporary file: {temp_file}")
                except Exception as e:
                    logger.warning(f"Failed to clean up temporary file {temp_file}: {e}")
            
            # Format response (same as URL processing)
            if result['success']:
                # Log stdout/stderr for debugging (always log, even on success)
                logger.info(f"Script execution successful. stdout length: {len(result['stdout'])}, stderr length: {len(result['stderr'])}")
                if result['stdout']:
                    sanitized_stdout = sanitize_subprocess_output(result['stdout'])
                    logger.info(f"Script stdout:\n{sanitized_stdout}")
                if result['stderr']:
                    sanitized_stderr = sanitize_subprocess_output(result['stderr'])
                    logger.info(f"Script stderr:\n{sanitized_stderr}")
                
                # Try to extract event ID and convert to nevent
                event_id = None
                nevent = None
                
                # Try stdout first
                if result['stdout']:
                    event_id = extract_event_id(result['stdout'])
                    if event_id:
                        logger.info(f"Extracted event ID from stdout: {event_id}")
                
                # If not found in stdout, try stderr
                if not event_id and result['stderr']:
                    event_id = extract_event_id(result['stderr'])
                    if event_id:
                        logger.info(f"Extracted event ID from stderr: {event_id}")
                
                # Encode to nevent if we found an event ID
                if event_id:
                    nevent = await encode_to_nevent(event_id)
                    logger.info(f"Encoded to nevent: {nevent}")
                else:
                    logger.warning(f"Could not extract event ID from stdout or stderr. stdout length: {len(result['stdout'])}, stderr length: {len(result['stderr'])}")
                    if result['stdout']:
                        sanitized_stdout = sanitize_subprocess_output(result['stdout'])
                        logger.warning(f"stdout content (first 500 chars): {sanitized_stdout[:500]}")
                    if result['stderr']:
                        sanitized_stderr = sanitize_subprocess_output(result['stderr'])
                        logger.warning(f"stderr content (first 500 chars): {sanitized_stderr[:500]}")
                
                if nevent:
                    # Format response with nostr client link if configured
                    if config.get('nostr_client_url'):
                        # Format the client URL with the nevent
                        client_url_template = config['nostr_client_url']
                        # Replace {nevent} placeholder if present, otherwise append nevent
                        if '{nevent}' in client_url_template:
                            client_url = client_url_template.format(nevent=nevent)
                        else:
                            # If no placeholder, append /e/nevent or just nevent depending on URL
                            if client_url_template.endswith('/'):
                                client_url = f"{client_url_template}e/{nevent}"
                            else:
                                client_url = f"{client_url_template}/e/{nevent}"
                        
                        # Create clickable link using Markdown format
                        response_msg = f"✅ [View on Nostr]({client_url})\n\n`{nevent}`"
                        if status_msg:
                            await send_message_with_retry(status_msg, response_msg, edit_text=True, parse_mode='Markdown')
                        else:
                            await send_message_with_retry(message, response_msg, parse_mode='Markdown')
                        logger.info(f"Successfully processed media files, nevent: {nevent}, client_url: {client_url}")
                    else:
                        # Return only the nevent formatted ID if no client URL configured
                        if status_msg:
                            await send_message_with_retry(status_msg, nevent, edit_text=True)
                        else:
                            await send_message_with_retry(message, nevent)
                        logger.info(f"Successfully processed media files, nevent: {nevent}")
                else:
                    # Fallback if we couldn't extract/encode event ID
                    logger.warning(f"Could not extract event ID from output for media files")
                    success_msg = f"✅ Successfully processed {len(media_files)} media file(s)"
                    if event_id:
                        success_msg += f"\nEvent ID: {event_id} (could not encode to nevent)"
                    if status_msg:
                        await send_message_with_retry(status_msg, success_msg, edit_text=True)
                    else:
                        await send_message_with_retry(message, success_msg)
            else:
                # Check for timeout first
                if result.get('timeout'):
                    timeout_seconds = config.get('script_timeout', 360)
                    error_parts = [f"⏱️ Script execution timed out after {timeout_seconds} seconds\n\nThe request took too long and was cancelled. This may happen with rate-limited sites."]
                    
                    # Include any captured output before timeout
                    if result.get('stderr'):
                        error_parts.append(result['stderr'])
                    if result.get('stdout') and 'Partial stdout' not in (result.get('stderr') or ''):
                        error_parts.append(f"\n--- Partial stdout before timeout ---\n{result['stdout']}")
                    
                    error_msg = "\n\n".join(error_parts)
                    
                    # Truncate if too long (Telegram limit)
                    MAX_ERROR_LENGTH = 3500
                    if len(error_msg) > MAX_ERROR_LENGTH:
                        truncated_msg = error_msg[-MAX_ERROR_LENGTH:]
                        first_newline = truncated_msg.find('\n')
                        if first_newline > 0 and first_newline < MAX_ERROR_LENGTH * 0.2:
                            truncated_msg = truncated_msg[first_newline+1:]
                        error_display = f"⏱️ Script execution timed out after {timeout_seconds} seconds\n\n... (truncated, full error in logs)\n\n{truncated_msg}"
                    else:
                        error_display = error_msg
                else:
                    # Combine stderr and stdout for error messages (bash scripts often use both)
                    error_parts = []
                if result['stderr']:
                    error_parts.append(f"Error:\n{result['stderr']}")
                if result['stdout']:
                    error_parts.append(f"Output:\n{result['stdout']}")
                
                error_msg = "\n\n".join(error_parts) if error_parts else "Unknown error"
                
                # Telegram has a 4096 character limit per message, so limit to ~3500 to leave room for prefix
                MAX_ERROR_LENGTH = 3500
                if len(error_msg) > MAX_ERROR_LENGTH:
                    # Truncate from the beginning, keep the end (most important part with actual error)
                    truncated_msg = error_msg[-MAX_ERROR_LENGTH:]
                    # Try to truncate at a newline if possible (find first newline in truncated message)
                    first_newline = truncated_msg.find('\n')
                    if first_newline > 0 and first_newline < MAX_ERROR_LENGTH * 0.2:  # If we can find a newline in the first 20%
                        truncated_msg = truncated_msg[first_newline+1:]
                    error_display = f"❌ Error processing media file(s)\n\n... (truncated, full error in logs)\n\n{truncated_msg}"
                else:
                    error_display = f"❌ Error processing media file(s)\n\n{error_msg}"
                
                if status_msg:
                    await send_message_with_retry(status_msg, error_display, edit_text=True)
                else:
                    await send_message_with_retry(message, error_display)
                logger.error(f"Error processing media files")
                sanitized_stderr = sanitize_subprocess_output(result['stderr'])
                sanitized_stdout = sanitize_subprocess_output(result['stdout'])
                logger.error(f"stderr: {sanitized_stderr}")
                logger.error(f"stdout: {sanitized_stdout}")
        except Exception as e:
            logger.exception(f"Exception while processing media files: {e}")
            # Try to send error message, but don't fail if it times out
            try:
                await send_message_with_retry(message, f"❌ Exception occurred: {str(e)}")
            except Exception as send_error:
                logger.error(f"Failed to send error message: {send_error}")
            # Clean up temporary files on error
            for temp_file in media_files:
                try:
                    if os.path.exists(temp_file):
                        os.unlink(temp_file)
                except Exception:
                    pass
        return
    
    # Extract URLs
    urls = extract_urls(text)
    
    if not urls:
        logger.info("No URLs found in message")
        return
    
    # Extract extra text after URLs
    extra_text = extract_extra_text(text, urls)
    
    # Try to send acknowledgment, but don't fail if it times out
    status_msg = None
    try:
        status_msg = await send_message_with_retry(
            message,
            f"Processing {len(urls)} URL(s): {urls[0][:50]}{'...' if len(urls[0]) > 50 else ''}..."
        )
        if status_msg is None:
            logger.warning("Could not send status message, continuing without it")
    except Exception as e:
        logger.warning(f"Failed to send status message: {e}, continuing without it")
    
    try:
        # Get disable_cookies_for_sites from channel config or global config
        # Use 'in' check to handle empty lists correctly (empty list means "don't disable for this channel")
        if 'disable_cookies_for_sites' in channel_config:
            disable_cookies_sites = channel_config.get('disable_cookies_for_sites')
        else:
            disable_cookies_sites = config.get('disable_cookies_for_sites')
        
        # Build command
        cmd = build_command(
            profile_name,
            config['script_path'],
            urls,
            extra_text,
            config.get('use_firefox', True),
            config.get('cookies_file'),
            config,
            channel_config.get('nsfw', False),  # Get NSFW setting from channel config
            disable_cookies_sites  # Get disable cookies setting from channel or global config
        )
        
        # Execute script with timeout
        timeout = config.get('script_timeout', 360)
        result = await execute_script(cmd, timeout=timeout)
        
        # Format response
        if result['success']:
            # Log stdout/stderr for debugging (always log, even on success)
            logger.info(f"Script execution successful. stdout length: {len(result['stdout'])}, stderr length: {len(result['stderr'])}")
            if result['stdout']:
                # Output is already sanitized in execute_script, but sanitize again as safety measure
                logger.info(f"Script stdout:\n{result['stdout']}")
            if result['stderr']:
                # Output is already sanitized in execute_script, but sanitize again as safety measure
                logger.info(f"Script stderr:\n{result['stderr']}")
            
            # Try to extract event ID and convert to nevent
            # Check both stdout and stderr, as the script might output to either
            event_id = None
            nevent = None
            
            # Try stdout first
            if result['stdout']:
                event_id = extract_event_id(result['stdout'])
                if event_id:
                    logger.info(f"Extracted event ID from stdout: {event_id}")
            
            # If not found in stdout, try stderr
            if not event_id and result['stderr']:
                event_id = extract_event_id(result['stderr'])
                if event_id:
                    logger.info(f"Extracted event ID from stderr: {event_id}")
            
            # Encode to nevent if we found an event ID
            if event_id:
                nevent = await encode_to_nevent(event_id)
                logger.info(f"Encoded to nevent: {nevent}")
            else:
                logger.warning(f"Could not extract event ID from stdout or stderr. stdout length: {len(result['stdout'])}, stderr length: {len(result['stderr'])}")
                if result['stdout']:
                    sanitized_stdout = sanitize_subprocess_output(result['stdout'])
                    logger.warning(f"stdout content (first 500 chars): {sanitized_stdout[:500]}")
                if result['stderr']:
                    sanitized_stderr = sanitize_subprocess_output(result['stderr'])
                    logger.warning(f"stderr content (first 500 chars): {sanitized_stderr[:500]}")
            
            if nevent:
                # Format response with nostr client link if configured
                if config.get('nostr_client_url'):
                    # Format the client URL with the nevent
                    # Common formats: https://snort.social/e/{nevent} or https://primal.net/e/{nevent}
                    client_url_template = config['nostr_client_url']
                    # Replace {nevent} placeholder if present, otherwise append nevent
                    if '{nevent}' in client_url_template:
                        client_url = client_url_template.format(nevent=nevent)
                    else:
                        # If no placeholder, append /e/nevent or just nevent depending on URL
                        if client_url_template.endswith('/'):
                            client_url = f"{client_url_template}e/{nevent}"
                        else:
                            client_url = f"{client_url_template}/e/{nevent}"
                    
                    # Create clickable link using Markdown format
                    response_msg = f"✅ [View on Nostr]({client_url})\n\n`{nevent}`"
                    if status_msg:
                        await send_message_with_retry(status_msg, response_msg, edit_text=True, parse_mode='Markdown')
                    else:
                        await send_message_with_retry(message, response_msg, parse_mode='Markdown')
                    logger.info(f"Successfully processed URLs: {urls}, nevent: {nevent}, client_url: {client_url}")
                else:
                    # Return only the nevent formatted ID if no client URL configured
                    if status_msg:
                        await send_message_with_retry(status_msg, nevent, edit_text=True)
                    else:
                        await send_message_with_retry(message, nevent)
                    logger.info(f"Successfully processed URLs: {urls}, nevent: {nevent}")
            else:
                # Fallback if we couldn't extract/encode event ID
                logger.warning(f"Could not extract event ID from output for URLs: {urls}")
                success_msg = f"✅ Successfully processed {len(urls)} URL(s)"
                if event_id:
                    success_msg += f"\nEvent ID: {event_id} (could not encode to nevent)"
                if status_msg:
                    await send_message_with_retry(status_msg, success_msg, edit_text=True)
                else:
                    await send_message_with_retry(message, success_msg)
        else:
            # Check for timeout first
            if result.get('timeout'):
                timeout_seconds = config.get('script_timeout', 360)
                error_parts = [f"⏱️ Script execution timed out after {timeout_seconds} seconds\n\nThe request took too long and was cancelled. This may happen with rate-limited sites."]
                
                # Include any captured output before timeout
                if result.get('stderr'):
                    error_parts.append(result['stderr'])
                if result.get('stdout') and 'Partial stdout' not in (result.get('stderr') or ''):
                    error_parts.append(f"\n--- Partial stdout before timeout ---\n{result['stdout']}")
                
                error_msg = "\n\n".join(error_parts)
                
                # Truncate if too long (Telegram limit)
                MAX_ERROR_LENGTH = 3500
                if len(error_msg) > MAX_ERROR_LENGTH:
                    truncated_msg = error_msg[-MAX_ERROR_LENGTH:]
                    first_newline = truncated_msg.find('\n')
                    if first_newline > 0 and first_newline < MAX_ERROR_LENGTH * 0.2:
                        truncated_msg = truncated_msg[first_newline+1:]
                    error_display = f"⏱️ Script execution timed out after {timeout_seconds} seconds\n\n... (truncated, full error in logs)\n\n{truncated_msg}"
                else:
                    error_display = error_msg
            else:
                # Combine stderr and stdout for error messages (bash scripts often use both)
                error_parts = []
            if result['stderr']:
                error_parts.append(f"Error:\n{result['stderr']}")
            if result['stdout']:
                error_parts.append(f"Output:\n{result['stdout']}")
            
            error_msg = "\n\n".join(error_parts) if error_parts else "Unknown error"
            
            # Telegram has a 4096 character limit per message, so limit to ~3500 to leave room for prefix
            MAX_ERROR_LENGTH = 3500
            if len(error_msg) > MAX_ERROR_LENGTH:
                # Truncate from the beginning, keep the end (most important part with actual error)
                truncated_msg = error_msg[-MAX_ERROR_LENGTH:]
                # Try to truncate at a newline if possible (find first newline in truncated message)
                first_newline = truncated_msg.find('\n')
                if first_newline > 0 and first_newline < MAX_ERROR_LENGTH * 0.2:  # If we can find a newline in the first 20%
                    truncated_msg = truncated_msg[first_newline+1:]
                error_display = f"❌ Error processing URL(s)\n\n... (truncated, full error in logs)\n\n{truncated_msg}"
            else:
                error_display = f"❌ Error processing URL(s)\n\n{error_msg}"
            
            if status_msg:
                await send_message_with_retry(status_msg, error_display, edit_text=True)
            else:
                await send_message_with_retry(message, error_display)
            logger.error(f"Error processing URLs {urls}")
            sanitized_stderr = sanitize_subprocess_output(result['stderr'])
            sanitized_stdout = sanitize_subprocess_output(result['stdout'])
            logger.error(f"stderr: {sanitized_stderr}")
            logger.error(f"stdout: {sanitized_stdout}")
    except Exception as e:
        logger.exception(f"Exception while processing message: {e}")
        # Try to send error message, but don't fail if it times out
        try:
            await send_message_with_retry(message, f"❌ Exception occurred: {str(e)}")
        except Exception as send_error:
            logger.error(f"Failed to send error message: {send_error}")


async def cleanup_all_processes():
    """Kill all tracked processes and their children."""
    if not running_processes:
        logger.info("No running processes to clean up")
        return
    
    logger.info(f"Cleaning up {len(running_processes)} tracked process(es)...")
    pids_to_kill = list(running_processes.keys())
    
    for pid in pids_to_kill:
        proc_info = running_processes.get(pid)
        if proc_info:
            cmd_str = ' '.join(str(arg) for arg in proc_info['cmd'][:3])  # Show first few args
            logger.info(f"Killing process tree for PID {pid} (command: {cmd_str}...)")
            try:
                await kill_process_tree(pid, timeout=5.0)
                if pid in running_processes:
                    del running_processes[pid]
            except Exception as e:
                logger.error(f"Error killing process {pid}: {e}")
    
    logger.info("Process cleanup completed")


def setup_signal_handlers():
    """Set up signal handlers for graceful shutdown."""
    def signal_handler(signum, frame):
        """Handle SIGINT and SIGTERM signals."""
        signal_name = signal.Signals(signum).name
        logger.info(f"Received {signal_name}, cleaning up {len(running_processes)} tracked process(es)...")
        
        # Kill all processes synchronously (using subprocess calls)
        if running_processes:
            pids_to_kill = list(running_processes.keys())
            for pid in pids_to_kill:
                logger.info(f"Killing process tree for PID {pid}...")
                try:
                    # Use synchronous process killing
                    if PSUTIL_AVAILABLE:
                        try:
                            parent = psutil.Process(pid)
                            children = parent.children(recursive=True)
                            all_procs = [parent] + children
                            for proc in all_procs:
                                try:
                                    proc.terminate()
                                except (psutil.NoSuchProcess, psutil.AccessDenied):
                                    pass
                            # Wait briefly
                            psutil.wait_procs(all_procs, timeout=2.0)
                            # Force kill remaining
                            for proc in all_procs:
                                try:
                                    if proc.is_running():
                                        proc.kill()
                                except (psutil.NoSuchProcess, psutil.AccessDenied):
                                    pass
                        except (psutil.NoSuchProcess, psutil.AccessDenied):
                            pass
                    elif os.name == 'nt':
                        # Windows: use taskkill
                        subprocess.run(['taskkill', '/F', '/T', '/PID', str(pid)], 
                                     timeout=5.0, capture_output=True)
                    else:
                        # Unix: use killpg
                        try:
                            os.killpg(os.getpgid(pid), signal.SIGTERM)
                            time.sleep(1)
                            os.killpg(os.getpgid(pid), signal.SIGKILL)
                        except (ProcessLookupError, OSError):
                            pass
                except Exception as e:
                    logger.error(f"Error killing process {pid}: {e}")
        
        logger.info("Process cleanup completed, exiting...")
        # Exit gracefully
        sys.exit(0)
    
    # Register signal handlers (only on Unix-like systems)
    if os.name != 'nt':
        signal.signal(signal.SIGINT, signal_handler)
        signal.signal(signal.SIGTERM, signal_handler)
    # On Windows, KeyboardInterrupt will be handled in the try/except block


def main() -> None:
    """Start the bot."""
    # Set up signal handlers for graceful shutdown
    setup_signal_handlers()
    
    # Parse command-line arguments
    parser = argparse.ArgumentParser(description='Telegram bot for nostr_media_uploader')
    parser.add_argument('--no-firefox', action='store_true',
                        help='Disable --firefox parameter when calling nostr_media_uploader.sh')
    parser.add_argument('--cookies', '--cookies-file', dest='cookies_file', default=None,
                        help='Path to cookies file (Mozilla/Netscape format). Takes precedence over --firefox option.')
    parser.add_argument('--config', default=CONFIG_FILE,
                        help=f'Path to configuration file (default: {CONFIG_FILE})')
    args = parser.parse_args()
    
    # Determine if Firefox should be used
    use_firefox = not args.no_firefox
    
    # Validate cookies file if provided
    if args.cookies_file and not os.path.exists(args.cookies_file):
        logger.warning(f"Cookies file specified but not found: {args.cookies_file}")
        # Don't exit, just log warning - user might fix it later
    
    # Load configuration
    try:
        config = load_config(args.config, use_firefox=use_firefox, cookies_file=args.cookies_file)
    except Exception as e:
        logger.error(f"Failed to load configuration: {e}")
        return
    
    if not config['bot_token']:
        logger.error("TELEGRAM_BOT_TOKEN not set in configuration")
        return
    
    if config['owner_id'] == 0:
        logger.error("TELEGRAM_OWNER_ID not set in configuration")
        return
    
    # Create application
    application = Application.builder().token(config['bot_token']).build()
    
    # Store config and config path in bot_data for access in handlers
    application.bot_data['config'] = config
    application.bot_data['config_path'] = args.config
    application.bot_data['use_firefox'] = use_firefox
    application.bot_data['cookies_file'] = args.cookies_file
    
    # Add message handler
    # With multi-channel support, we listen to all chats and filter in the handler
    # based on channel configuration and owner_id
    # Support text, captions, photos, videos, and documents
    message_filter = filters.TEXT | filters.CAPTION | filters.PHOTO | filters.VIDEO | filters.Document.ALL
    
    application.add_handler(MessageHandler(message_filter, handle_message))
    
    # Start the bot
    logger.info("Starting bot...")
    logger.info(f"Owner ID: {config['owner_id']}")
    logger.info(f"Script path: {config['script_path']}")
    if config.get('cookies_file'):
        logger.info(f"Cookies file: {config['cookies_file']}")
    else:
        logger.info(f"Use Firefox: {config.get('use_firefox', True)}")
    channels = config.get('channels', {})
    if channels:
        logger.info(f"Configured channels: {len(channels)}")
        for channel_name, channel_config in channels.items():
            chat_id = channel_config.get('chat_id', 'N/A')
            profile_name = channel_config.get('profile_name', 'N/A')
            logger.info(f"  - {channel_name}: chat_id={chat_id}, profile_name={profile_name}")
    else:
        logger.info("No channels configured - will only process messages from owner")
    logger.info("Bot is ready and listening for messages...")
    
    # Run the bot with cleanup on shutdown
    try:
        application.run_polling(allowed_updates=Update.ALL_TYPES)
    except KeyboardInterrupt:
        logger.info("Received KeyboardInterrupt (Ctrl+C), cleaning up processes...")
        # Kill all processes synchronously (for Windows and Unix)
        if running_processes:
            logger.info(f"Cleaning up {len(running_processes)} tracked process(es)...")
            pids_to_kill = list(running_processes.keys())
            for pid in pids_to_kill:
                logger.info(f"Killing process tree for PID {pid}...")
                try:
                    if PSUTIL_AVAILABLE:
                        try:
                            parent = psutil.Process(pid)
                            children = parent.children(recursive=True)
                            all_procs = [parent] + children
                            for proc in all_procs:
                                try:
                                    proc.terminate()
                                except (psutil.NoSuchProcess, psutil.AccessDenied):
                                    pass
                            # Wait briefly
                            psutil.wait_procs(all_procs, timeout=2.0)
                            # Force kill remaining
                            for proc in all_procs:
                                try:
                                    if proc.is_running():
                                        proc.kill()
                                except (psutil.NoSuchProcess, psutil.AccessDenied):
                                    pass
                        except (psutil.NoSuchProcess, psutil.AccessDenied):
                            pass
                    elif os.name == 'nt':
                        # Windows: use taskkill
                        subprocess.run(['taskkill', '/F', '/T', '/PID', str(pid)], 
                                     timeout=5.0, capture_output=True)
                    else:
                        # Unix: use killpg
                        try:
                            os.killpg(os.getpgid(pid), signal.SIGTERM)
                            time.sleep(1)
                            os.killpg(os.getpgid(pid), signal.SIGKILL)
                        except (ProcessLookupError, OSError):
                            pass
                except Exception as e:
                    logger.error(f"Error killing process {pid}: {e}")
        logger.info("Process cleanup completed, exiting...")
        raise


if __name__ == '__main__':
    main()

