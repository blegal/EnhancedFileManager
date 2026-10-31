import Foundation
import libzstd
import CLZ4

/// Compression en flux embarquée (zstd et LZ4, sans outil externe) : le tar du système produit ou lit
/// l'archive non compressée par un tube, et ces codecs la compressent ou la décompressent au passage.
enum StreamCodec {
    case zstd, lz4

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// `.tar.zst` / `.tzst` / `.tar.lz4` (ou `.zst` / `.lz4` seuls).
    init?(archive: URL) {
        let name = archive.lastPathComponent.lowercased()
        if name.hasSuffix(".zst") || name.hasSuffix(".tzst") { self = .zstd }
        else if name.hasSuffix(".lz4") { self = .lz4 }
        else { return nil }
    }

    private static let chunk = 1 << 20

    // MARK: Compression

    func compress(from input: FileHandle, to output: FileHandle, progress: (Int64) -> Void, isCancelled: () -> Bool) throws {
        switch self {
        case .zstd: try Self.zstdCompress(input, output, progress, isCancelled)
        case .lz4: try Self.lz4Compress(input, output, progress, isCancelled)
        }
    }

    func decompress(from input: FileHandle, to output: FileHandle, progress: (Int64) -> Void, isCancelled: () -> Bool) throws {
        switch self {
        case .zstd: try Self.zstdDecompress(input, output, progress, isCancelled)
        case .lz4: try Self.lz4Decompress(input, output, progress, isCancelled)
        }
    }

    private static func zstdCompress(_ input: FileHandle, _ output: FileHandle, _ progress: (Int64) -> Void, _ isCancelled: () -> Bool) throws {
        guard let context = ZSTD_createCCtx() else { throw Failure(message: "zstd : mémoire insuffisante") }
        defer { ZSTD_freeCCtx(context) }
        ZSTD_CCtx_setParameter(context, ZSTD_c_compressionLevel, 6)
        ZSTD_CCtx_setParameter(context, ZSTD_c_checksumFlag, 1)
        var buffer = [UInt8](repeating: 0, count: ZSTD_CStreamOutSize())
        var done: Int64 = 0
        var finished = false
        while !finished {
            if isCancelled() { throw CancellationError() }
            let data = try input.read(upToCount: chunk) ?? Data()
            let mode = data.isEmpty ? ZSTD_e_end : ZSTD_e_continue
            try data.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
                var inBuffer = ZSTD_inBuffer(src: source.baseAddress, size: source.count, pos: 0)
                repeat {
                    let (remaining, produced) = buffer.withUnsafeMutableBytes { target -> (Int, Int) in
                        var outBuffer = ZSTD_outBuffer(dst: target.baseAddress, size: target.count, pos: 0)
                        let result = ZSTD_compressStream2(context, &outBuffer, &inBuffer, mode)
                        return (result, outBuffer.pos)
                    }
                    if ZSTD_isError(remaining) != 0 { throw Failure(message: "zstd : " + String(cString: ZSTD_getErrorName(remaining))) }
                    if produced > 0 { try output.write(contentsOf: buffer[0..<produced]) }
                    if mode == ZSTD_e_end { finished = remaining == 0 } else if inBuffer.pos == inBuffer.size { break }
                } while !finished
            }
            done += Int64(data.count)
            progress(done)
        }
    }

    private static func zstdDecompress(_ input: FileHandle, _ output: FileHandle, _ progress: (Int64) -> Void, _ isCancelled: () -> Bool) throws {
        guard let context = ZSTD_createDCtx() else { throw Failure(message: "zstd : mémoire insuffisante") }
        defer { ZSTD_freeDCtx(context) }
        var buffer = [UInt8](repeating: 0, count: ZSTD_DStreamOutSize())
        var done: Int64 = 0
        while let data = try input.read(upToCount: chunk), !data.isEmpty {
            if isCancelled() { throw CancellationError() }
            try data.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
                var inBuffer = ZSTD_inBuffer(src: source.baseAddress, size: source.count, pos: 0)
                while inBuffer.pos < inBuffer.size {
                    let (result, produced) = buffer.withUnsafeMutableBytes { target -> (Int, Int) in
                        var outBuffer = ZSTD_outBuffer(dst: target.baseAddress, size: target.count, pos: 0)
                        let result = ZSTD_decompressStream(context, &outBuffer, &inBuffer)
                        return (result, outBuffer.pos)
                    }
                    if ZSTD_isError(result) != 0 { throw Failure(message: "zstd : " + String(cString: ZSTD_getErrorName(result))) }
                    if produced > 0 { try output.write(contentsOf: buffer[0..<produced]) }
                }
            }
            done += Int64(data.count)
            progress(done)
        }
    }

    private static func lz4Check(_ code: Int) throws -> Int {
        if LZ4F_isError(code) != 0 { throw Failure(message: "LZ4 : " + String(cString: LZ4F_getErrorName(code))) }
        return code
    }

    private static func lz4Compress(_ input: FileHandle, _ output: FileHandle, _ progress: (Int64) -> Void, _ isCancelled: () -> Bool) throws {
        var context: OpaquePointer?
        _ = try lz4Check(LZ4F_createCompressionContext(&context, UInt32(LZ4F_VERSION)))
        defer { LZ4F_freeCompressionContext(context) }
        var preferences = LZ4F_preferences_t()
        preferences.frameInfo.contentChecksumFlag = LZ4F_contentChecksumEnabled
        preferences.frameInfo.blockSizeID = LZ4F_max4MB
        var buffer = [UInt8](repeating: 0, count: LZ4F_compressBound(chunk, &preferences) + 64)
        let capacity = buffer.count
        let header = try lz4Check(buffer.withUnsafeMutableBytes { LZ4F_compressBegin(context, $0.baseAddress, capacity, &preferences) })
        try output.write(contentsOf: buffer[0..<header])
        var done: Int64 = 0
        while let data = try input.read(upToCount: chunk), !data.isEmpty {
            if isCancelled() { throw CancellationError() }
            let produced = try lz4Check(data.withUnsafeBytes { source in
                buffer.withUnsafeMutableBytes { LZ4F_compressUpdate(context, $0.baseAddress, capacity, source.baseAddress, source.count, nil) }
            })
            if produced > 0 { try output.write(contentsOf: buffer[0..<produced]) }
            done += Int64(data.count)
            progress(done)
        }
        let tail = try lz4Check(buffer.withUnsafeMutableBytes { LZ4F_compressEnd(context, $0.baseAddress, capacity, nil) })
        try output.write(contentsOf: buffer[0..<tail])
    }

    private static func lz4Decompress(_ input: FileHandle, _ output: FileHandle, _ progress: (Int64) -> Void, _ isCancelled: () -> Bool) throws {
        var context: OpaquePointer?
        _ = try lz4Check(LZ4F_createDecompressionContext(&context, UInt32(LZ4F_VERSION)))
        defer { LZ4F_freeDecompressionContext(context) }
        var buffer = [UInt8](repeating: 0, count: 4 << 20)
        var done: Int64 = 0
        while let data = try input.read(upToCount: chunk), !data.isEmpty {
            if isCancelled() { throw CancellationError() }
            try data.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
                var offset = 0
                while offset < source.count {
                    var sourceSize = source.count - offset
                    var produced = buffer.count
                    _ = try lz4Check(buffer.withUnsafeMutableBytes {
                        LZ4F_decompress(context, $0.baseAddress, &produced, source.baseAddress! + offset, &sourceSize, nil)
                    })
                    offset += sourceSize
                    if produced > 0 { try output.write(contentsOf: buffer[0..<produced]) }
                    if sourceSize == 0 && produced == 0 { break }
                }
            }
            done += Int64(data.count)
            progress(done)
        }
    }

    // MARK: Avec tar

    /// Crée `target` : tar des `names` (relatifs à `directory`) compressé au passage.
    func createTar(_ names: [String], in directory: URL, to target: URL, job: FileJob) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-c", "--no-mac-metadata", "-f", "-", "-C", directory.path, "--"] + names
        let pipe = Pipe(), errors = Pipe()
        process.standardOutput = pipe
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        job.setCancelAction { process.terminate() }
        FileManager.default.createFile(atPath: target.path, contents: nil)
        let output = try FileHandle(forWritingTo: target)
        defer { try? output.close() }
        try process.run()
        var failure: Error?
        do {
            try compress(from: pipe.fileHandleForReading, to: output, progress: { job.waitIfPaused(); job.setDone($0) },
                         isCancelled: { job.isCancelled })
        } catch {
            failure = error
            process.terminate()
        }
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        if let failure { throw failure }
        if process.terminationStatus != 0 { throw Failure(message: message.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    /// Décompresse `archive` dans `folder` (tar lit le flux décompressé).
    func extractTar(_ archive: URL, into folder: URL, extraArguments: [String] = [], job: FileJob?) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-x", "-f", "-", "-C", folder.path] + extraArguments
        let pipe = Pipe(), errors = Pipe()
        process.standardInput = pipe
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        job?.setCancelAction { process.terminate() }
        let input = try FileHandle(forReadingFrom: archive)
        defer { try? input.close() }
        try process.run()
        // Les erreurs sont lues en parallèle : un tar bavard ne bloque pas le tube.
        var message = Data()
        let reader = DispatchGroup()
        reader.enter()
        DispatchQueue.global().async {
            message = errors.fileHandleForReading.readDataToEndOfFile()
            reader.leave()
        }
        var failure: Error?
        do {
            try decompress(from: input, to: pipe.fileHandleForWriting, progress: { job?.waitIfPaused(); job?.setDone($0) },
                           isCancelled: { job?.isCancelled ?? false })
        } catch {
            failure = error
        }
        try? pipe.fileHandleForWriting.close()
        process.waitUntilExit()
        reader.wait()
        if let failure { throw failure }
        if process.terminationStatus != 0 {
            throw Failure(message: String(decoding: message, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
