import Foundation

/// Incremental IEEE CRC-32 used by the deliberately small ZIP32 writer.
/// Keeping it in Core makes the archive preflight independent of UIKit or a
/// third-party ZIP library.
public enum RoomCRC32 {
    private static let ieeeTable: [UInt32] = (0..<256).map { seed in
        var value = UInt32(seed)
        for _ in 0..<8 {
            value = (value & 1) == 1
                ? (value >> 1) ^ 0xedb8_8320
                : value >> 1
        }
        return value
    }

    public struct Stream: Sendable {
        private var rawValue: UInt32 = 0xffff_ffff

        public init() {}

        public mutating func update(_ data: Data) {
            for byte in data {
                let index = Int((rawValue ^ UInt32(byte)) & 0xff)
                rawValue = (rawValue >> 8) ^ RoomCRC32.ieeeTable[index]
            }
        }

        public var finalizedValue: UInt32 {
            rawValue ^ 0xffff_ffff
        }
    }
}
