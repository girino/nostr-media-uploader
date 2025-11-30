# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Initial release with full cross-platform support (Linux/Cygwin)
- OS detection and automatic platform-specific optimizations
- Comprehensive command validation with installation instructions
- Intelligent video codec conversion with hardware acceleration support
- Automatic encoder selection (h265 hardware > h264 hardware > h265 software > h264 software)
- Hardware encoder detection for QSV, NVENC, and AMF
- History tracking to prevent duplicate uploads
- Support for multiple Nostr blossom servers with automatic fallback
- Gallery support with intelligent caption placement
- Facebook URL processing with position inference
- Firefox cookie integration for authenticated downloads
- Environment-based configuration system
- Profile support for aiart.sh script

### Changed
- Repository cleaned of all hardcoded keys from git history
- Script renamed from `linchuanchuan.sh` to `nostr_media_uploader.sh`
- Improved error handling and error messages
- Enhanced video conversion with robust fallback mechanisms

### Fixed
- Video conversion failures now prevent upload of incompatible files
- Empty blossom server entries are filtered out
- History file is automatically created if missing
- Environment file is optional (no longer causes fatal errors)
- Line ending issues resolved (Unix LF line endings)

### Security
- All hardcoded keys removed from git history
- Clean history starting from commit 72e1fbf
- Environment-based key management (no keys in code)

## [1.0.0] - 2025-11-30

### Initial Release
- Full feature set as described above
- Cross-platform compatibility
- Comprehensive documentation

