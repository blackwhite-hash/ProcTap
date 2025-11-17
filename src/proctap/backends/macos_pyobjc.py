"""
macOS audio capture backend using PyObjC and Core Audio API.

This module provides process-specific audio capture on macOS 14.4+ using
native PyObjC bindings to Core Audio Process Tap API.

This is a replacement for the Swift CLI helper approach, providing:
- Direct Python integration (no subprocess overhead)
- Better error handling and debugging
- Simpler deployment (pip install only)
- Reduced latency (~5-10ms improvement)

Requirements:
- macOS 14.4 (Sonoma) or later
- PyObjC: pip install pyobjc-core pyobjc-framework-CoreAudio
- Audio capture permission (NSMicrophoneUsageDescription)

STATUS: Phase 1 - Prototype Implementation
"""

from __future__ import annotations

from typing import Optional, Callable
import logging
import platform
from ctypes import c_uint32, c_void_p, POINTER, byref

logger = logging.getLogger(__name__)

# Type alias for audio callback
AudioCallback = Callable[[bytes, int], None]

# Check if PyObjC is available
try:
    from Foundation import NSObject
    from CoreAudio import (
        # System object
        kAudioObjectSystemObject,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,

        # Properties
        kAudioHardwarePropertyTranslatePIDToProcessObject,

        # Functions
        AudioObjectGetPropertyData,
        AudioObjectHasProperty,

        # Types
        AudioObjectPropertyAddress,
        AudioObjectID,
    )

    PYOBJC_AVAILABLE = True
    logger.debug("PyObjC CoreAudio framework loaded successfully")

except ImportError as e:
    PYOBJC_AVAILABLE = False
    logger.warning(f"PyObjC not available: {e}")
    # Define dummy types to avoid NameError
    NSObject = object  # type: ignore
    AudioObjectPropertyAddress = object  # type: ignore


def is_available() -> bool:
    """
    Check if PyObjC Core Audio bindings are available.

    Returns:
        True if PyObjC is installed and Core Audio can be accessed
    """
    return PYOBJC_AVAILABLE


def get_macos_version() -> tuple[int, int, int]:
    """
    Get macOS version as tuple (major, minor, patch).

    Returns:
        Tuple of (major, minor, patch) version numbers

    Example:
        (14, 4, 0) for macOS 14.4.0 Sonoma
    """
    try:
        version_str = platform.mac_ver()[0]
        parts = version_str.split('.')
        major = int(parts[0]) if len(parts) > 0 else 0
        minor = int(parts[1]) if len(parts) > 1 else 0
        patch = int(parts[2]) if len(parts) > 2 else 0
        return (major, minor, patch)
    except Exception as e:
        logger.warning(f"Failed to parse macOS version: {e}")
        return (0, 0, 0)


def supports_process_tap() -> bool:
    """
    Check if the current macOS version supports Process Tap API.

    Returns:
        True if macOS 14.4+, False otherwise
    """
    major, minor, _ = get_macos_version()
    return major > 14 or (major == 14 and minor >= 4)


class ProcessAudioDiscovery:
    """
    Discover Core Audio objects for a process by PID.

    This class wraps the Core Audio API for translating process IDs to
    Core Audio object IDs.
    """

    def __init__(self):
        """
        Initialize process audio discovery.

        Raises:
            RuntimeError: If PyObjC is not available or macOS version is too old
        """
        if not PYOBJC_AVAILABLE:
            raise RuntimeError(
                "PyObjC Core Audio bindings not available. "
                "Install with: pip install pyobjc-core pyobjc-framework-CoreAudio"
            )

        if not supports_process_tap():
            major, minor, patch = get_macos_version()
            raise RuntimeError(
                f"macOS {major}.{minor}.{patch} does not support Process Tap API. "
                "Requires macOS 14.4 (Sonoma) or later."
            )

    def get_process_object_id(self, pid: int) -> Optional[int]:
        """
        Translate process ID to Core Audio object ID.

        Args:
            pid: Target process ID

        Returns:
            Core Audio object ID (AudioObjectID), or None if not found

        Raises:
            RuntimeError: If API call fails
        """
        try:
            # Create property address for PID translation
            address = AudioObjectPropertyAddress()
            address.mSelector = kAudioHardwarePropertyTranslatePIDToProcessObject
            address.mScope = kAudioObjectPropertyScopeGlobal
            address.mElement = kAudioObjectPropertyElementMain

            # Check if property exists
            has_property = AudioObjectHasProperty(
                kAudioObjectSystemObject,
                address
            )

            if not has_property:
                logger.error(
                    "kAudioHardwarePropertyTranslatePIDToProcessObject not available. "
                    "This may indicate macOS version < 14.4."
                )
                return None

            # Input data: PID as UInt32
            pid_data = c_uint32(pid)
            qualifier_data_size = 4  # sizeof(UInt32)

            # Output data: AudioObjectID (UInt32)
            process_object_id = AudioObjectID()
            out_data_size = c_uint32(4)  # sizeof(AudioObjectID)

            # Get property data
            # OSStatus AudioObjectGetPropertyData(
            #     AudioObjectID inObjectID,
            #     const AudioObjectPropertyAddress *inAddress,
            #     UInt32 inQualifierDataSize,
            #     const void *inQualifierData,
            #     UInt32 *ioDataSize,
            #     void *outData
            # )
            status = AudioObjectGetPropertyData(
                kAudioObjectSystemObject,
                address,
                qualifier_data_size,
                byref(pid_data),
                byref(out_data_size),
                byref(process_object_id)
            )

            if status != 0:
                logger.error(
                    f"AudioObjectGetPropertyData failed with status {status}. "
                    f"Process {pid} may not have audio output."
                )
                return None

            logger.debug(
                f"Translated PID {pid} to AudioObjectID {process_object_id.value}"
            )
            return int(process_object_id.value)

        except Exception as e:
            logger.error(f"Error translating PID to process object: {e}")
            raise RuntimeError(
                f"Failed to get process object for PID {pid}: {e}"
            ) from e

    def find_process_with_audio(self, pid: int) -> bool:
        """
        Check if a process has active audio output.

        Args:
            pid: Process ID to check

        Returns:
            True if process has Core Audio object, False otherwise
        """
        try:
            object_id = self.get_process_object_id(pid)
            return object_id is not None and object_id != 0
        except Exception as e:
            logger.error(f"Error checking process audio: {e}")
            return False


# Phase 1 Prototype: Process Discovery Only
# This is a minimal implementation to test PyObjC integration
# Future phases will add:
# - Process Tap creation (AudioHardwareCreateProcessTap)
# - Audio I/O setup (AudioDeviceCreateIOProcID, AudioDeviceStart)
# - Format configuration (AudioStreamBasicDescription)
# - Buffer management and callback handling
# - Integration with MacOSBackend


if __name__ == "__main__":
    # Test code for development
    import sys

    logging.basicConfig(
        level=logging.DEBUG,
        format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
    )

    if not is_available():
        print("ERROR: PyObjC Core Audio not available")
        print("Install with: pip install pyobjc-core pyobjc-framework-CoreAudio")
        sys.exit(1)

    if not supports_process_tap():
        major, minor, patch = get_macos_version()
        print(f"ERROR: macOS {major}.{minor}.{patch} does not support Process Tap")
        print("Requires macOS 14.4 (Sonoma) or later")
        sys.exit(1)

    print("✓ PyObjC Core Audio available")
    print(f"✓ macOS version: {'.'.join(map(str, get_macos_version()))}")

    # Test process discovery
    if len(sys.argv) > 1:
        try:
            test_pid = int(sys.argv[1])
            print(f"\nTesting process discovery for PID {test_pid}...")

            discovery = ProcessAudioDiscovery()
            has_audio = discovery.find_process_with_audio(test_pid)

            if has_audio:
                object_id = discovery.get_process_object_id(test_pid)
                print(f"✓ Process {test_pid} has audio (ObjectID: {object_id})")
            else:
                print(f"✗ Process {test_pid} does not have active audio output")

        except ValueError:
            print(f"ERROR: Invalid PID: {sys.argv[1]}")
            sys.exit(1)
        except Exception as e:
            print(f"ERROR: {e}")
            import traceback
            traceback.print_exc()
            sys.exit(1)
    else:
        print("\nUsage: python -m proctap.backends.macos_pyobjc <PID>")
        print("Example: python -m proctap.backends.macos_pyobjc 1234")
