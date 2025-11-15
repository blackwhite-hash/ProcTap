import Foundation
import CoreAudio
import AudioToolbox

/// Exit codes for the CLI
enum ExitCode: Int32 {
    case success = 0
    case invalidArguments = 1
    case unsupportedOS = 2
    case processNotFound = 3
    case audioSetupFailed = 4
    case captureError = 5
}

/// Command-line arguments
struct Arguments {
    let pid: pid_t
    let sampleRate: Double
    let channels: UInt32

    static func parse() -> Arguments? {
        let args = CommandLine.arguments

        var pid: pid_t?
        var sampleRate: Double = 48000.0
        var channels: UInt32 = 2

        var i = 1
        while i < args.count {
            switch args[i] {
            case "--pid":
                guard i + 1 < args.count, let value = pid_t(args[i + 1]) else {
                    fputs("Error: Invalid --pid argument\n", stderr)
                    return nil
                }
                pid = value
                i += 2

            case "--sample-rate":
                guard i + 1 < args.count, let value = Double(args[i + 1]) else {
                    fputs("Error: Invalid --sample-rate argument\n", stderr)
                    return nil
                }
                sampleRate = value
                i += 2

            case "--channels":
                guard i + 1 < args.count, let value = UInt32(args[i + 1]) else {
                    fputs("Error: Invalid --channels argument\n", stderr)
                    return nil
                }
                channels = value
                i += 2

            default:
                fputs("Error: Unknown argument: \(args[i])\n", stderr)
                return nil
            }
        }

        guard let validPID = pid else {
            fputs("Error: --pid is required\n", stderr)
            return nil
        }

        return Arguments(pid: validPID, sampleRate: sampleRate, channels: channels)
    }
}

/// Process Audio Tap Manager
class ProcessAudioTap {
    private let pid: pid_t
    private let sampleRate: Double
    private let channels: UInt32

    private var tap: AudioObjectID = 0
    private var device: AudioObjectID = 0
    private var ioProcID: AudioDeviceIOProcID?

    init(pid: pid_t, sampleRate: Double, channels: UInt32) {
        self.pid = pid
        self.sampleRate = sampleRate
        self.channels = channels
    }

    /// Start capturing audio from the process
    func start() throws {
        // Step 1: Get process object ID from PID
        let processObject = try getProcessObject(for: pid)
        fputs("Process object ID: \(processObject)\n", stderr)

        // Step 2: Create process tap
        tap = try createProcessTap(for: processObject)
        fputs("Process tap created: \(tap)\n", stderr)

        // Step 3: Create aggregate device with the tap
        device = try createAggregateDevice(with: tap)
        fputs("Aggregate device created: \(device)\n", stderr)

        // Step 4: Set up IOProc to capture audio
        try setupIOProc()
        fputs("IOProc set up successfully\n", stderr)

        // Step 5: Start the device
        try startDevice()
        fputs("Audio capture started for PID \(pid)\n", stderr)
    }

    /// Stop capturing audio
    func stop() {
        if let procID = ioProcID {
            AudioDeviceDestroyIOProcID(device, procID)
        }

        if device != 0 {
            AudioHardwareDestroyAggregateDevice(device)
        }

        if tap != 0 {
            // Note: Process taps are automatically cleaned up by the system
        }

        fputs("Audio capture stopped\n", stderr)
    }

    // MARK: - Private Helper Methods

    private func getProcessObject(for pid: pid_t) throws -> AudioObjectID {
        var processObject: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.size)

        var translation = AudioObjectID(pid)

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            ),
            UInt32(MemoryLayout<AudioObjectID>.size),
            &translation,
            &size,
            &processObject
        )

        guard status == noErr else {
            throw NSError(
                domain: "com.proctap.error",
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "Failed to get process object: \(status)"]
            )
        }

        return processObject
    }

    private func createProcessTap(for processObject: AudioObjectID) throws -> AudioObjectID {
        var tapID: AudioObjectID = 0

        // Create tap description
        var tapDesc = CATapDescription()
        tapDesc.mIncludeProcesses = (processObject, 0, 0, 0, 0, 0, 0, 0)
        tapDesc.mIncludeProcessesCount = 1
        tapDesc.mExcludeProcesses = (0, 0, 0, 0, 0, 0, 0, 0)
        tapDesc.mExcludeProcessesCount = 0
        tapDesc.mProcessingType = kAudioTapProcessingTypeMixDown
        tapDesc.mName = ("ProcTap".utf8CString + Array(repeating: 0, count: 256))[0..<256].map { Int8($0) }
            .withUnsafeBufferPointer { buffer in
                var name = (Int8(0), Int8(0), Int8(0), Int8(0), Int8(0), Int8(0), Int8(0), Int8(0),
                           Int8(0), Int8(0), Int8(0), Int8(0), Int8(0), Int8(0), Int8(0), Int8(0))
                for i in 0..<min(buffer.count, 16) {
                    withUnsafeMutableBytes(of: &name) { ptr in
                        ptr[i] = UInt8(bitPattern: buffer[i])
                    }
                }
                return name
            }
        tapDesc.mMuteBehavior = kAudioTapMuteBehaviorDoNotMute

        let status = AudioHardwareCreateProcessTap(&tapDesc, &tapID)

        guard status == noErr else {
            throw NSError(
                domain: "com.proctap.error",
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "Failed to create process tap: \(status)"]
            )
        }

        return tapID
    }

    private func createAggregateDevice(with tap: AudioObjectID) throws -> AudioObjectID {
        var deviceID: AudioObjectID = 0

        // Create aggregate device dictionary
        let deviceDict: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "ProcTap Aggregate",
            kAudioAggregateDeviceUIDKey as String: "com.proctap.aggregate.\(UUID().uuidString)",
            kAudioAggregateDeviceSubDeviceListKey as String: [tap],
            kAudioAggregateDeviceMasterSubDeviceKey as String: tap
        ]

        let status = AudioHardwareCreateAggregateDevice(deviceDict as CFDictionary, &deviceID)

        guard status == noErr else {
            throw NSError(
                domain: "com.proctap.error",
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "Failed to create aggregate device: \(status)"]
            )
        }

        return deviceID
    }

    private func setupIOProc() throws {
        var procID: AudioDeviceIOProcID?

        let callback: AudioDeviceIOProc = { (
            inDevice: AudioObjectID,
            inNow: UnsafePointer<AudioTimeStamp>,
            inInputData: UnsafePointer<AudioBufferList>,
            inInputTime: UnsafePointer<AudioTimeStamp>,
            outOutputData: UnsafeMutablePointer<AudioBufferList>,
            inOutputTime: UnsafePointer<AudioTimeStamp>,
            inClientData: UnsafeMutableRawPointer?
        ) -> OSStatus in
            // Read audio data from input buffer
            let bufferList = inInputData.pointee

            if bufferList.mNumberBuffers > 0 {
                let buffer = bufferList.mBuffers
                if let data = buffer.mData, buffer.mDataByteSize > 0 {
                    // Write PCM data to stdout
                    let bytes = data.assumingMemoryBound(to: UInt8.self)
                    let written = fwrite(bytes, 1, Int(buffer.mDataByteSize), stdout)
                    fflush(stdout)

                    if written != Int(buffer.mDataByteSize) {
                        fputs("Warning: Failed to write all audio data\n", stderr)
                    }
                }
            }

            return noErr
        }

        let status = AudioDeviceCreateIOProcID(
            device,
            callback,
            nil,
            &procID
        )

        guard status == noErr, let validProcID = procID else {
            throw NSError(
                domain: "com.proctap.error",
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "Failed to create IOProc: \(status)"]
            )
        }

        ioProcID = validProcID
    }

    private func startDevice() throws {
        guard let procID = ioProcID else {
            throw NSError(
                domain: "com.proctap.error",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "IOProc not initialized"]
            )
        }

        let status = AudioDeviceStart(device, procID)

        guard status == noErr else {
            throw NSError(
                domain: "com.proctap.error",
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "Failed to start device: \(status)"]
            )
        }
    }
}

// MARK: - Main Entry Point

func main() -> Int32 {
    // Parse arguments
    guard let args = Arguments.parse() else {
        fputs("Usage: proctap-macos --pid <PID> [--sample-rate <rate>] [--channels <num>]\n", stderr)
        return ExitCode.invalidArguments.rawValue
    }

    // Check macOS version
    if #unavailable(macOS 14.4) {
        fputs("Error: Process Tap API requires macOS 14.4 or later\n", stderr)
        return ExitCode.unsupportedOS.rawValue
    }

    // Create and start tap
    let tap = ProcessAudioTap(
        pid: args.pid,
        sampleRate: args.sampleRate,
        channels: args.channels
    )

    do {
        try tap.start()

        // Run indefinitely until killed
        fputs("Capturing audio... (Press Ctrl+C to stop)\n", stderr)
        RunLoop.current.run()

    } catch {
        fputs("Error: \(error.localizedDescription)\n", stderr)
        return ExitCode.captureError.rawValue
    }

    return ExitCode.success.rawValue
}

// Run the main function
exit(main())
