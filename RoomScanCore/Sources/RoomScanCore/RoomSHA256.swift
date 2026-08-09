import Foundation

/// Small incremental SHA-256 implementation kept in the Foundation-only core.
/// Evidence files can be large, so `hexDigest(ofFile:)` reads bounded chunks
/// instead of loading a native USDZ or mesh artifact into memory at once.
public enum RoomSHA256 {
    /// A small value-type streaming hasher. Export and evidence validation use
    /// this instead of loading large USDZ/mesh files into memory.
    public struct Stream: Sendable {
        private var state = State()

        public init() {}

        public mutating func update(_ data: Data) {
            state.update(data)
        }

        public mutating func finalizedHexDigest() -> String {
            state.finalizedHexDigest()
        }
    }

    public static func hexDigest(of data: Data) -> String {
        var stream = Stream()
        stream.update(data)
        return stream.finalizedHexDigest()
    }

    public static func hexDigest(
        ofFile url: URL,
        chunkSize: Int = 64 * 1024
    ) throws -> String {
        guard chunkSize > 0 else {
            throw RoomProjectStoreError.storageFailure("SHA-256 chunk size must be positive.")
        }

        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw RoomProjectStoreError.storageFailure("Unable to open an evidence file for hashing.")
        }
        defer { try? handle.close() }

        var stream = Stream()
        do {
            while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
                stream.update(chunk)
            }
        } catch {
            throw RoomProjectStoreError.storageFailure("Unable to hash an evidence file.")
        }
        return stream.finalizedHexDigest()
    }

    private struct State: Sendable {
    private static let roundConstants: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
        0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
        0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
        0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
        0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
        0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
        0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
        0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
        0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    private var hash: [UInt32] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    ]
    private var pendingBytes: [UInt8] = []
    private var messageBitCount: UInt64 = 0

    mutating func update(_ data: Data) {
        let bytes = [UInt8](data)
        messageBitCount &+= UInt64(bytes.count) &* 8
        absorb(bytes)
    }

    mutating func finalizedHexDigest() -> String {
        var finalBytes = pendingBytes
        finalBytes.append(0x80)
        while finalBytes.count % 64 != 56 {
            finalBytes.append(0)
        }
        for shift in stride(from: 56, through: 0, by: -8) {
            finalBytes.append(UInt8(truncatingIfNeeded: messageBitCount >> UInt64(shift)))
        }

        var finalState = self
        for start in stride(from: 0, to: finalBytes.count, by: 64) {
            finalState.process(Array(finalBytes[start..<(start + 64)]))
        }
        return finalState.hash.map { String(format: "%08x", $0) }.joined()
    }

    private mutating func absorb(_ bytes: [UInt8]) {
        var offset = 0
        if !pendingBytes.isEmpty {
            let needed = 64 - pendingBytes.count
            let take = min(needed, bytes.count)
            pendingBytes.append(contentsOf: bytes[0..<take])
            offset = take
            if pendingBytes.count == 64 {
                process(pendingBytes)
                pendingBytes.removeAll(keepingCapacity: true)
            }
        }

        while offset + 64 <= bytes.count {
            process(Array(bytes[offset..<(offset + 64)]))
            offset += 64
        }
        if offset < bytes.count {
            pendingBytes.append(contentsOf: bytes[offset..<bytes.count])
        }
    }

    private mutating func process(_ block: [UInt8]) {
        precondition(block.count == 64)
        var schedule = [UInt32](repeating: 0, count: 64)
        for index in 0..<16 {
            let offset = index * 4
            schedule[index] =
                (UInt32(block[offset]) << 24)
                | (UInt32(block[offset + 1]) << 16)
                | (UInt32(block[offset + 2]) << 8)
                | UInt32(block[offset + 3])
        }
        for index in 16..<64 {
            let sigma0 = rotateRight(schedule[index - 15], by: 7)
                ^ rotateRight(schedule[index - 15], by: 18)
                ^ (schedule[index - 15] >> 3)
            let sigma1 = rotateRight(schedule[index - 2], by: 17)
                ^ rotateRight(schedule[index - 2], by: 19)
                ^ (schedule[index - 2] >> 10)
            schedule[index] = schedule[index - 16]
                &+ sigma0
                &+ schedule[index - 7]
                &+ sigma1
        }

        var a = hash[0]
        var b = hash[1]
        var c = hash[2]
        var d = hash[3]
        var e = hash[4]
        var f = hash[5]
        var g = hash[6]
        var h = hash[7]

        for index in 0..<64 {
            let sum1 = rotateRight(e, by: 6)
                ^ rotateRight(e, by: 11)
                ^ rotateRight(e, by: 25)
            let choice = (e & f) ^ (~e & g)
            let temporary1 = h &+ sum1 &+ choice &+ Self.roundConstants[index] &+ schedule[index]
            let sum0 = rotateRight(a, by: 2)
                ^ rotateRight(a, by: 13)
                ^ rotateRight(a, by: 22)
            let majority = (a & b) ^ (a & c) ^ (b & c)
            let temporary2 = sum0 &+ majority

            h = g
            g = f
            f = e
            e = d &+ temporary1
            d = c
            c = b
            b = a
            a = temporary1 &+ temporary2
        }

        hash[0] &+= a
        hash[1] &+= b
        hash[2] &+= c
        hash[3] &+= d
        hash[4] &+= e
        hash[5] &+= f
        hash[6] &+= g
        hash[7] &+= h
    }

    private func rotateRight(_ value: UInt32, by count: UInt32) -> UInt32 {
        (value >> count) | (value << (32 - count))
    }
}
