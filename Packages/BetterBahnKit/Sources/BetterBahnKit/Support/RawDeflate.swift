#if canImport(Compression)
import Compression
#elseif canImport(CZlib)
import CZlib
#endif
import Foundation

/// Raw DEFLATE (RFC 1951, no zlib header), as share links and UIC ticket barcodes carry it. Apple's
/// `Compression` on iOS; zlib on Android, where `Compression` doesn't exist (`Android/kit/Package.swift`).
enum RawDeflate {
    /// Compressed `data`, or nil when that fails.
    static func deflate(_ data: Data) -> Data? {
        #if canImport(Compression)
        return try? (data as NSData).compressed(using: .zlib) as Data
        #elseif canImport(CZlib)
        return zlib(data, compressing: true, limit: Int.max)
        #else
        return nil
        #endif
    }

    /// `data` inflated, or nil when it's malformed, empty or would grow beyond `limit` bytes.
    static func inflate(_ data: Data, limit: Int) -> Data? {
        guard !data.isEmpty else { return nil }
        #if canImport(Compression)
        let capacity = limit + 1
        var output = Data(count: capacity)
        let size = output.withUnsafeMutableBytes { out in
            data.withUnsafeBytes { input in
                compression_decode_buffer(out.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                          input.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard size > 0, size <= limit else { return nil }
        return output.prefix(size)
        #elseif canImport(CZlib)
        guard let output = zlib(data, compressing: false, limit: limit), !output.isEmpty else { return nil }
        return output
        #else
        return nil
        #endif
    }

    #if !canImport(Compression) && canImport(CZlib)
    /// zlib's stream API with negative window bits, which means raw DEFLATE.
    private static func zlib(_ data: Data, compressing: Bool, limit: Int) -> Data? {
        var stream = z_stream()
        let start = compressing
            ? deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY,
                            ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
            : inflateInit2_(&stream, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard start == Z_OK else { return nil }
        defer { _ = compressing ? deflateEnd(&stream) : inflateEnd(&stream) }

        var input = [UInt8](data)
        var output = Data()
        let chunk = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: chunk)
        return input.withUnsafeMutableBufferPointer { inputPointer -> Data? in
            stream.next_in = inputPointer.baseAddress
            stream.avail_in = uInt(inputPointer.count)
            while true {
                let status: Int32 = buffer.withUnsafeMutableBufferPointer { out in
                    stream.next_out = out.baseAddress
                    stream.avail_out = uInt(chunk)
                    return compressing ? CZlib.deflate(&stream, Z_FINISH) : CZlib.inflate(&stream, Z_NO_FLUSH)
                }
                output.append(contentsOf: buffer[0..<(chunk - Int(stream.avail_out))])
                if output.count > limit { return nil }
                if status == Z_STREAM_END { return output }
                guard status == Z_OK || (status == Z_BUF_ERROR && stream.avail_in > 0) else { return nil }
                // Inflating input that ends early: no progress left to make.
                if !compressing && stream.avail_in == 0 && stream.avail_out != 0 { return nil }
            }
        }
    }
    #endif
}
