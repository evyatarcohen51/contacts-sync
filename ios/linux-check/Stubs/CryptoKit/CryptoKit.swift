// CryptoKit on Linux is swift-crypto, which has the same API.
@_exported import Crypto
import Foundation

// NSData.compressed(using:) does not exist on Linux. This writes valid raw DEFLATE
// (RFC 1951) using "stored" blocks, which is what `.zlib` means on Apple platforms
// minus the actual compression. Any inflater reads it.
extension NSData {
    public enum CompressionAlgorithm: Int, Sendable {
        case lzfse, lz4, lzma, zlib
    }

    public func compressed(using algorithm: CompressionAlgorithm) throws -> NSData {
        precondition(algorithm == .zlib, "only .zlib is implemented in the stub")
        let input = [UInt8](Data(referencing: self))
        var out = [UInt8]()
        out.reserveCapacity(input.count + input.count / 65535 * 5 + 5)
        var offset = 0
        repeat {
            let n = Swift.min(65535, input.count - offset)
            let last: UInt8 = offset + n >= input.count ? 1 : 0
            out.append(last) // BFINAL bit, BTYPE = 00 (stored)
            out.append(UInt8(n & 0xff)); out.append(UInt8(n >> 8))
            out.append(UInt8(~n & 0xff)); out.append(UInt8((~n >> 8) & 0xff))
            out.append(contentsOf: input[offset..<offset + n])
            offset += n
        } while offset < input.count
        return NSData(data: Data(out))
    }
}
