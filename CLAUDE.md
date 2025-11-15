# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

ProcTap is a cross-platform Python library for capturing audio from specific processes. It provides platform-specific backends for Windows, Linux (under development), and macOS (planned).

**Platform Support:**
- **Windows**: ✅ Fully implemented using WASAPI Process Loopback (C++ native extension)
- **Linux**: 🚧 Under development - PulseAudio/PipeWire backend (stub implementation)
- **macOS**: ❌ Not yet implemented - planned for future support

**Key Characteristics:**
- Per-process audio isolation (not system-wide)
- Low-latency streaming (10ms default buffer on Windows)
- Windows 10 20H1+ required for Windows backend
- Dual API: callback-based and async iterator patterns

## Development Commands

### Setup and Building

```bash
# Install in editable mode with dev dependencies
pip install -e ".[dev]"

# Build wheel (requires Visual Studio Build Tools + Windows SDK)
python -m build --wheel

# Build source distribution
python -m build
```

**Important:** After modifying C++ code in [_native.cpp](src/proctap/_native.cpp), you must rebuild:
```bash
pip install -e . --force-reinstall --no-deps
```

### Testing and Type Checking

```bash
# Run tests
pytest

# Type check
mypy src/
```

### Running Examples

```bash
# Capture by process ID
python examples/record_proc_to_wav.py --pid 12345 --output audio.wav

# Capture by process name (requires psutil)
python examples/record_proc_to_wav.py --name "VRChat.exe" --output audio.wav
```

## Architecture

### Multi-Platform Backend Architecture

The library uses platform-specific backends selected at runtime:

```
ProcTap (core.py - Public API)
    ↓
backends/__init__.py (Platform Detection)
    ↓
┌────────────────┬──────────────────┬─────────────────┐
│ Windows        │ Linux            │ macOS           │
│ (Implemented)  │ (In Development) │ (Planned)       │
├────────────────┼──────────────────┼─────────────────┤
│ WindowsBackend │ LinuxBackend     │ MacOSBackend    │
│ └─ _native.cpp │ └─ PulseAudio/   │ └─ Core Audio/  │
│    (WASAPI)    │    PipeWire      │    ScreenKit    │
└────────────────┴──────────────────┴─────────────────┘
```

**Backend Selection** ([backends/__init__.py](src/proctap/backends/__init__.py)):
- Automatic platform detection using `platform.system()`
- Windows: Uses native C++ extension with WASAPI
- Linux: Stub implementation with TODO markers (development in progress)
- macOS: Raises `NotImplementedError` (not yet implemented)

**Windows Backend** ([backends/windows.py](src/proctap/backends/windows.py)):
- Wraps `_native.cpp` C++ extension
- Per-process audio capture requires `ActivateAudioInterfaceAsync` (Windows 10 20H1+)
- Fixed audio format: 44.1kHz, 2ch, 16-bit PCM

**Linux Backend** ([backends/linux.py](src/proctap/backends/linux.py)):
- 🧪 Experimental - PulseAudio support implemented
- Uses `pulsectl` library for PulseAudio interaction
- Captures from sink monitor using `parec` command
- Strategy pattern allows future PipeWire native support
- **Limitation:** Currently captures from entire sink (not per-app isolated)
- Requires: `pulsectl` library, `parec` command, target process must be playing audio

**macOS Backend** ([backends/macos.py](src/proctap/backends/macos.py)):
- ❌ Not yet implemented
- Potential approach: ScreenCaptureKit API (macOS 12.3+)
- See file for research notes

### Threading Model

Audio capture runs on a background thread to prevent blocking:

1. **Worker Thread**: Reads from WASAPI capture buffer continuously
2. **Main Thread**: Receives data via callbacks or async queue
3. **Synchronization**: Thread-safe queue for async iteration, direct callbacks for callback mode

**Data Flow:**
```
Audio Source (Process-specific)
  → Platform Backend (WASAPI/PulseAudio/CoreAudio)
  → Worker Thread
  → Queue/Callback
  → User Code
```

### Key Components

**[core.py](src/proctap/core.py)** - Main API surface:
- `ProcessAudioTap`: User-facing class with two operation modes:
  - Callback mode: `start(on_data=callback)`
  - Async mode: `async for chunk in tap.iter_chunks()`
  - Uses platform-specific backend via `get_backend()`
- `StreamConfig`: Audio format configuration (exists for API compatibility but may not affect all backends)

**[backends/](src/proctap/backends/)** - Platform-specific implementations:
- `base.py`: `AudioBackend` abstract base class
- `windows.py`: Windows implementation (wraps `_native.cpp`)
- `linux.py`: Linux implementation (under development)
- `macos.py`: macOS implementation (not implemented)

**[_native.cpp](src/proctap/_native.cpp)** - Windows C++ Extension:
- `ProcessLoopback` class: WASAPI capture implementation
- Uses `ActivateAudioInterfaceAsync` for process-specific capture
- COM/WRL integration with proper apartment threading
- Exposes methods: `start()`, `stop()`, `read()`, `get_format()`

## Build System Details

**Platform-Specific Builds:**

The build system ([setup.py](setup.py)) automatically detects the platform and builds appropriate extensions:

**Windows Build Requirements:**
- Visual Studio Build Tools (MSVC compiler)
- Windows SDK
- Python 3.10+ (supports 3.10, 3.11, 3.12, 3.13)
- C++20 compiler (`/std:c++20` flag)

**Windows Linked Libraries:**
- `ole32`: COM infrastructure
- `uuid`: GUID support
- `propsys`: Property system

**Extension Module:** Builds as `_native.cp3XX-win_amd64.pyd` (Windows only)

**Linux/macOS Builds:**
- No C++ extension required (pure Python)
- Backend functionality limited (see platform support status above)

## Python Dependencies

**Runtime:**
- **Windows**: No Python dependencies (uses native C++ extension)
- **Linux**: `pulsectl>=23.5.0` (automatically installed via environment markers in pyproject.toml)
- **macOS**: No dependencies (not yet implemented)

**System Dependencies (Linux only):**
- `parec` command from `pulseaudio-utils` package
- PulseAudio or PipeWire with pulseaudio-compat

**Optional:**
- `psutil`: Used in examples for process name → PID resolution

**Development:**
- `pytest`: Test framework
- `mypy`: Type checking
- `types-setuptools`: Type stubs for setuptools

## Audio Format

**Windows Backend:**

The Windows native extension uses a **fixed audio format** hardcoded in [_native.cpp:329-336](src/proctap/_native.cpp#L329-L336):

- **Sample Rate:** 44,100 Hz (CD quality)
- **Channels:** 2 (stereo)
- **Bits per Sample:** 16-bit
- **Format:** PCM (WAVE_FORMAT_PCM)
- **Block Align:** 4 bytes (2 channels × 16 bits / 8)
- **Byte Rate:** 176,400 bytes/sec

**Note:** The `StreamConfig` class exists in Python but does not affect the Windows backend format. The format is fixed at the C++ level and cannot be changed without recompiling the extension.

**Linux/macOS Backends:**

Audio format will be determined by the respective backend implementations when completed.

Raw PCM data is returned as `bytes` to user callbacks/iterators.

## Known Issues and TODOs

**Windows Backend:**
1. **Frame Count Calculation** ([core.py:201](src/proctap/core.py#L201)):
   - Currently returns `-1` for frame count in callbacks
   - TODO: Calculate from backend format info

2. **Buffer Size Control** ([core.py:29](src/proctap/core.py#L29)):
   - `buffer_ms` parameter exists but note indicates limited control

**Linux Backend (Experimental):**
1. **PulseAudio Integration** ([backends/linux.py](src/proctap/backends/linux.py)):
   - ✅ Basic PulseAudio capture implemented
   - ✅ Process stream detection via application.process.id property
   - ⚠️ Limitation: Captures from entire sink monitor (not per-app isolated)
   - TODO: Implement proper per-app isolation using module-remap-source
   - TODO: Add native PipeWire support (PipeWireStrategy class)
   - TODO: Improve error handling and edge cases

**macOS Backend (Not Implemented):**
1. **ScreenCaptureKit Investigation** ([backends/macos.py](src/proctap/backends/macos.py)):
   - TODO: Research ScreenCaptureKit API feasibility
   - TODO: Prototype implementation
   - See file for potential approaches

**General:**
1. **Test Coverage:**
   - No test suite currently in repository (pytest configured but no tests written)
   - TODO: Add platform-specific backend tests

## CI/CD Workflows

GitHub Actions workflows in [.github/workflows/](.github/workflows/):

- **[build-wheels.yml](.github/workflows/build-wheels.yml)**: Multi-version wheel builds (Python 3.10-3.13)
- **[publish-pypi.yml](.github/workflows/publish-pypi.yml)**: Manual PyPI release trigger
- **[release-testpypi.yml](.github/workflows/release-testpypi.yml)**: TestPyPI releases

**Note:** Current workflows use Windows runners. Future TODO: Add Linux/macOS runners when respective backends are implemented.
