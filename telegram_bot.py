#!/usr/bin/env python3
"""
Telegram bot that listens for links from the owner and calls nostr_media_uploader.sh
"""

import os
import re
import subprocess
import asyncio
import logging
import configparser
import argparse
from pathlib import Path
from telegram import Update
from telegram.ext import Application, MessageHandler, filters, ContextTypes


# Configure logging
logging.basicConfig(
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    level=logging.INFO
)
logger = logging.getLogger(__name__)

# Configuration
CONFIG_FILE = os.getenv('TELEGRAM_BOT_CONFIG', 'telegram_bot.conf')

# URL regex pattern to match http/https links
URL_PATTERN = re.compile(
    r'http[s]?://(?:[a-zA-Z]|[0-9]|[$-_@.&+]|[!*\\(\\),]|(?:%[0-9a-fA-F][0-9a-fA-F]))+'
)


def load_config(config_path, use_firefox=True):
    """Load configuration from file."""
    config = configparser.ConfigParser()
    if not os.path.exists(config_path):
        logger.error(f"Configuration file not found: {config_path}")
        raise FileNotFoundError(f"Configuration file not found: {config_path}")
    
    config.read(config_path)
    
    telegram_section = config['telegram']
    return {
        'bot_token': telegram_section.get('bot_token'),
        'owner_id': int(telegram_section.get('owner_id', 0)),
        'chat_id': telegram_section.get('chat_id'),
        'profile_name': telegram_section.get('profile_name', 'tarado'),
        'script_path': telegram_section.get('script_path', './nostr_media_uploader.sh'),
        'use_firefox': use_firefox,
    }


def extract_urls(text):
    """Extract all URLs from a text message."""
    if not text:
        return []
    return URL_PATTERN.findall(text)


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
            logger.warning(f"nak encode nevent failed: {stderr}")
    except Exception as e:
        logger.warning(f"Failed to encode nevent using nak: {e}")
    
    return None


def convert_path_for_cygwin(path):
    """Convert Windows path to Cygwin path if running on Cygwin."""
    if not os.path.exists(path):
        return path
    
    # Check if running on Cygwin
    try:
        result = subprocess.run(
            ['cygpath', '-u', path],
            capture_output=True,
            text=True,
            timeout=5
        )
        if result.returncode == 0:
            return result.stdout.strip()
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
        # Not Cygwin or cygpath not available
        pass
    
    return path


def build_command(profile_name, script_path, urls, extra_text, use_firefox=True):
    """Build the command to execute nostr_media_uploader.sh."""
    # Convert script path to absolute path
    script_path = Path(script_path)
    if not script_path.is_absolute():
        script_dir = Path(__file__).parent.absolute()
        script_path = script_dir / script_path
    
    script_path = str(script_path)
    
    # Convert to Cygwin path if needed
    script_path = convert_path_for_cygwin(script_path)
    
    # Build command: bash script_path -p profile_name [--firefox] url1 url2 ... "extra_text"
    cmd = ['bash', script_path, '-p', profile_name]
    
    # Always add --firefox unless explicitly disabled
    if use_firefox:
        cmd.append('--firefox')
        logger.info("Adding --firefox parameter")
    
    # Add all URLs as separate arguments
    cmd.extend(urls)
    
    # Add extra text if present
    if extra_text:
        cmd.append(extra_text)
    
    return cmd


async def execute_script(cmd, cwd=None):
    """Execute the script and capture output."""
    try:
        logger.info(f"Executing: {' '.join(cmd)}")
        
        process = await asyncio.create_subprocess_exec(
            *cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            cwd=cwd or Path(__file__).parent
        )
        
        stdout_bytes, stderr_bytes = await process.communicate()
        
        # Decode bytes to strings
        stdout = stdout_bytes.decode('utf-8', errors='replace') if stdout_bytes else ''
        stderr = stderr_bytes.decode('utf-8', errors='replace') if stderr_bytes else ''
        
        return {
            'returncode': process.returncode,
            'stdout': stdout,
            'stderr': stderr,
            'success': process.returncode == 0
        }
    except Exception as e:
        logger.exception(f"Exception while executing script: {e}")
        return {
            'returncode': -1,
            'stdout': '',
            'stderr': str(e),
            'success': False
        }


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
    # For channel posts: check if sender_chat matches configured chat_id
    # (Channel posts don't have from_user, so we rely on chat_id match)
    is_owner = False
    
    if message.from_user:
        # Regular message - check if user ID matches owner_id
        is_owner = (message.from_user.id == config['owner_id'])
        if not is_owner:
            logger.info(f"Message from non-owner user {message.from_user.id}, ignoring")
            return
    elif message.sender_chat:
        # Channel post - check if it's from the configured chat_id
        # Since channel posts don't have from_user, we allow if chat_id matches
        sender_chat_id = str(message.sender_chat.id)
        chat_id_str = str(message.chat.id) if message.chat.id else None
        if config['chat_id']:
            expected_chat = str(config['chat_id'])
            # Check both sender_chat.id and message.chat.id (they should be the same for channel posts)
            is_owner = (sender_chat_id == expected_chat or 
                       chat_id_str == expected_chat or
                       (message.sender_chat.username and 
                        message.sender_chat.username == expected_chat.lstrip('@')) or
                       (message.chat.username and 
                        message.chat.username == expected_chat.lstrip('@')))
            if not is_owner:
                logger.info(f"Channel post from sender_chat={sender_chat_id}, chat={chat_id_str}, expected={expected_chat}, ignoring")
                return
            else:
                logger.info(f"Channel post accepted: sender_chat={sender_chat_id}, chat={chat_id_str} matches expected={expected_chat}")
        else:
            # No chat_id configured, reject channel posts
            logger.info(f"Channel post from chat {sender_chat_id} but no chat_id configured, ignoring")
            return
    else:
        logger.info("Message has no from_user or sender_chat, ignoring")
        return
    
    # Additional check: verify message is from the configured chat (if chat_id is set)
    # This provides an extra layer of filtering
    if config['chat_id']:
        chat_id = str(message.chat.id) if message.chat.id else None
        chat_username = message.chat.username if message.chat.username else None
        expected_chat = str(config['chat_id'])
        
        # Allow numeric ID or username match
        if chat_id != expected_chat and (not chat_username or chat_username != expected_chat.lstrip('@')):
            logger.info(f"Message from chat {chat_id}/{chat_username}, expected {expected_chat}, ignoring")
            return
    
    # Extract text from message
    text = message.text or message.caption or ""
    
    # Extract URLs
    urls = extract_urls(text)
    
    if not urls:
        logger.info("No URLs found in message")
        return
    
    # Extract extra text after URLs
    extra_text = extract_extra_text(text, urls)
    
    try:
        # Send acknowledgment
        status_msg = await message.reply_text(
            f"Processing {len(urls)} URL(s): {urls[0][:50]}{'...' if len(urls[0]) > 50 else ''}..."
        )
        
        # Build command
        cmd = build_command(
            config['profile_name'],
            config['script_path'],
            urls,
            extra_text,
            config.get('use_firefox', True)
        )
        
        # Execute script
        result = await execute_script(cmd)
        
        # Format response
        if result['success']:
            # Try to extract event ID and convert to nevent
            event_id = None
            nevent = None
            
            if result['stdout']:
                event_id = extract_event_id(result['stdout'])
                if event_id:
                    nevent = await encode_to_nevent(event_id)
                    logger.info(f"Extracted event ID: {event_id}, nevent: {nevent}")
            
            if nevent:
                # Return only the nevent formatted ID
                await status_msg.edit_text(nevent)
                logger.info(f"Successfully processed URLs: {urls}, nevent: {nevent}")
            else:
                # Fallback if we couldn't extract/encode event ID
                logger.warning(f"Could not extract event ID from output for URLs: {urls}")
                success_msg = f"✅ Successfully processed {len(urls)} URL(s)"
                if event_id:
                    success_msg += f"\nEvent ID: {event_id} (could not encode to nevent)"
                await status_msg.edit_text(success_msg)
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
                # Truncate but keep the most important part (usually the end has the actual error)
                truncated_msg = error_msg[:MAX_ERROR_LENGTH]
                # Try to truncate at a newline if possible
                last_newline = truncated_msg.rfind('\n')
                if last_newline > MAX_ERROR_LENGTH * 0.8:  # If we can find a newline in the last 20%
                    truncated_msg = truncated_msg[:last_newline]
                error_display = f"❌ Error processing URL(s)\n\n{truncated_msg}\n\n... (truncated, full error in logs)"
            else:
                error_display = f"❌ Error processing URL(s)\n\n{error_msg}"
            
            await status_msg.edit_text(error_display)
            logger.error(f"Error processing URLs {urls}")
            logger.error(f"stderr: {result['stderr']}")
            logger.error(f"stdout: {result['stdout']}")
            
    except Exception as e:
        logger.exception(f"Exception while processing message: {e}")
        await message.reply_text(f"❌ Exception occurred: {str(e)}")


def main() -> None:
    """Start the bot."""
    # Parse command-line arguments
    parser = argparse.ArgumentParser(description='Telegram bot for nostr_media_uploader')
    parser.add_argument('--no-firefox', action='store_true',
                        help='Disable --firefox parameter when calling nostr_media_uploader.sh')
    parser.add_argument('--config', default=CONFIG_FILE,
                        help=f'Path to configuration file (default: {CONFIG_FILE})')
    args = parser.parse_args()
    
    # Determine if Firefox should be used
    use_firefox = not args.no_firefox
    
    # Load configuration
    try:
        config = load_config(args.config, use_firefox=use_firefox)
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
    
    # Store config in bot_data for access in handlers
    application.bot_data['config'] = config
    
    # Add message handler
    # Filter by chat_id if specified, otherwise listen to all chats (only owner messages will be processed)
    message_filter = filters.TEXT | filters.CAPTION
    if config['chat_id']:
        try:
            chat_id_int = int(config['chat_id'])
            message_filter = message_filter & filters.Chat(chat_id=chat_id_int)
        except ValueError:
            # If CHAT_ID is not a number, assume it's a username (e.g., @channelname)
            message_filter = message_filter & filters.Chat(username=config['chat_id'].lstrip('@'))
    
    application.add_handler(MessageHandler(message_filter, handle_message))
    
    # Start the bot
    logger.info("Starting bot...")
    logger.info(f"Owner ID: {config['owner_id']}")
    logger.info(f"Chat ID: {config['chat_id'] or '(not set - will accept any chat)'}")
    logger.info(f"Profile name: {config['profile_name']}")
    logger.info(f"Script path: {config['script_path']}")
    logger.info(f"Use Firefox: {config.get('use_firefox', True)}")
    logger.info("Bot is ready and listening for messages...")
    
    application.run_polling(allowed_updates=Update.ALL_TYPES)


if __name__ == '__main__':
    main()

