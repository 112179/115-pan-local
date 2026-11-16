import Foundation
import CommonCrypto
import BigInt

/// 115 直连用到的加密层：
/// - RSA（1024 位，公钥运算 / PKCS#1 v1.5 加密）
/// - 固定密钥 AES-128-CBC
/// - LZ4 分块解压
enum Cipher115 {
    static let rsaModulusHex = "8686980c0f5a24c4b9d43020cd2c22703ff3f450756529058b1cf88f09b8602136477198a6e2683149659bd122c33592fdb5ad47944ad1ea4d36c6b172aad6338c3bb6ac6227502d010993ac967d1aef00f0c8e038de2e4d3bc2ec368af2e9f10a6f1eda4f7262f136420c07c331b871bf139f74f3010e3c4fe57df3afb71683"
    static let rsaExponent = BigUInt(65537)
    static let rsaModulus = BigUInt(rsaModulusHex, radix: 16)!

    static let aesKey: [UInt8] = [0xfb, 0x1a, 0x19, 0xd6, 0x52, 0xf5, 0xaa, 0xf7,
                                  0xbc, 0x65, 0x1d, 0x0f, 0x69, 0xbf, 0x42, 0x2f]
    static let aesIV: [UInt8] = [0x69, 0xbf, 0x42, 0x2f, 0x49, 0x96, 0x05, 0x50,
                                 0xa0, 0xad, 0x44, 0xec, 0x34, 0x46, 0xcb, 0x4c]
    static let xorKey: [UInt8] = [0x8d, 0xa5, 0xa5, 0x8d]
    static let gKeyL: [UInt8] = [0x78, 0x06, 0xad, 0x4c, 0x33, 0x86, 0x5d, 0x18,
                                 0x4c, 0x01, 0x3f, 0x46]

    static let gKTS: [UInt8] = [UInt8](hex: "f0e569aebfdcbf8a1a45e8be7da673b8de8fe7c445da86c49b648b146ab4f1aa3801359e26692c86006b4fa5363462a62a966818f24afdbd6b978f4d8f8913b76c8e93ed0e0d483ed72f88d8fefe7e8650954fd1eb832634db667b9c7e9d7a8132eab633de3aa95934663baaba816048b9d5819cf86c8477ff5478265fbee81e369f34805c452c9b76d51b8fccc3b8f5")

    // MARK: - XOR

    static func xorBytes(_ data: [UInt8], _ key: [UInt8]) -> [UInt8] {
        guard !key.isEmpty else { return data }
        var out = data
        var index = 0
        let prefix = data.count % 4
        if prefix > 0 {
            for i in 0..<prefix {
                out[i] = data[i] ^ key[i % key.count]
            }
            index = prefix
        }
        while index < data.count {
            let size = min(key.count, data.count - index)
            for i in 0..<size {
                out[index + i] = data[index + i] ^ key[i]
            }
            index += size
        }
        return out
    }

    static func rsaGenKey(_ randKey: [UInt8], length skLen: Int = 4) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: skLen)
        var offset = skLen * (skLen - 1)
        var index = 0
        for i in 0..<skLen where i < randKey.count {
            let x = (UInt16(randKey[i]) + UInt16(gKTS[index % gKTS.count])) & 0xff
            out[i] = gKTS[offset % gKTS.count] ^ UInt8(x)
            offset -= skLen
            index += skLen
        }
        return out
    }

    // MARK: - RSA

    /// 115 的 RSA 数据是 128 字节一块，必须逐块做公钥运算再拼接，
    /// 整串一次性算会得到乱码（真实响应通常 2 块以上）。
    static func rsaPublicOp(_ data: [UInt8], blockSize: Int = 128) -> [UInt8] {
        var out: [UInt8] = []
        var index = 0
        while index < data.count {
            let end = min(index + blockSize, data.count)
            let c = BigUInt(Data(data[index..<end]))
            let p = c.power(rsaExponent, modulus: rsaModulus)
            var bytes = Array(p.serialize())
            if let zero = bytes.firstIndex(of: 0) {
                bytes = Array(bytes[(zero + 1)...])
            }
            out += bytes
            index = end
        }
        return out
    }

    static func rsaEncryptBlocks(_ data: [UInt8], blockSize: Int = 128) -> [UInt8] {
        var out: [UInt8] = []
        var index = 0
        let chunkSize = blockSize - 11
        while index < data.count {
            let end = min(index + chunkSize, data.count)
            let chunk = Array(data[index..<end])
            var block = [UInt8](repeating: 0x02, count: blockSize - 3 - chunk.count)
            block.insert(contentsOf: [0x00, 0x02], at: 0)
            block.append(0x00)
            block.append(contentsOf: chunk)
            let m = BigUInt(Data(block))
            let c = m.power(rsaExponent, modulus: rsaModulus)
            var bytes = Array(c.serialize())
            if bytes.count < blockSize {
                bytes = [UInt8](repeating: 0, count: blockSize - bytes.count) + bytes
            }
            out += bytes
            index = end
        }
        return out
    }

    /// 115 自定义的 RSA 封装（加密请求内容）
    static func rsaEncrypt(_ data: [UInt8]) -> String {
        let randKey = [UInt8](repeating: 0, count: 16)
        let tmp = Array(xorBytes(data, xorKey).reversed())
        let plain = randKey + xorBytes(tmp, gKeyL)
        return Data(rsaEncryptBlocks(plain)).base64EncodedString()
    }

    /// 115 自定义的 RSA 解封装（解密响应内容）
    static func rsaDecrypt(_ base64: String) -> [UInt8]? {
        guard let cipher = Data(base64Encoded: base64) else { return nil }
        let raw = rsaPublicOp(Array(cipher))
        guard raw.count > 16 else { return nil }
        let randKey = Array(raw[0..<16])
        let keyL = rsaGenKey(randKey, length: 12)
        let mid = Array(xorBytes(Array(raw[16...]), keyL).reversed())
        return xorBytes(mid, xorKey)
    }

    // MARK: - AES-CBC

    static func aesEncrypt(_ data: [UInt8]) -> [UInt8] {
        aesCBC(data, encrypt: true)
    }

    static func aesDecrypt(_ data: [UInt8]) -> [UInt8] {
        aesCBC(data, encrypt: false)
    }

    private static func aesCBC(_ input: [UInt8], encrypt: Bool) -> [UInt8] {
        guard !input.isEmpty else { return [] }
        let operation = CCOperation(encrypt ? kCCEncrypt : kCCDecrypt)
        let options = CCOptions(encrypt ? kCCOptionPKCS7Padding : 0)
        var source = input
        if !encrypt {
            let usable = input.count - (input.count % 16)
            guard usable > 0 else { return [] }
            source = Array(input[0..<usable])
        }

        var output = [UInt8](repeating: 0, count: source.count + kCCBlockSizeAES128)
        var moved = 0
        let status = output.withUnsafeMutableBytes { outBuf in
            source.withUnsafeBytes { inBuf in
                aesKey.withUnsafeBytes { keyBuf in
                    aesIV.withUnsafeBytes { ivBuf in
                        CCCrypt(operation,
                                CCAlgorithm(kCCAlgorithmAES),
                                options,
                                keyBuf.baseAddress, aesKey.count,
                                ivBuf.baseAddress,
                                inBuf.baseAddress, source.count,
                                outBuf.baseAddress, outBuf.count,
                                &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return [] }
        let bytes = Array(output[0..<moved])
        return encrypt ? bytes : unpad(bytes)
    }

    private static func unpad(_ data: [UInt8]) -> [UInt8] {
        guard let last = data.last, last > 0, last < 16, Int(last) <= data.count else { return data }
        let pad = Int(last)
        let tail = data[(data.count - pad)...]
        return tail.allSatisfy { $0 == last } ? Array(data[0..<(data.count - pad)]) : data
    }

    // MARK: - LZ4

    static func lz4Decompress(_ data: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var index = 0
        while index + 2 <= data.count {
            let length = Int(data[index]) | (Int(data[index + 1]) << 8)
            index += 2
            guard length > 0, index + length <= data.count else { break }
            out += lz4BlockDecompress(Array(data[index..<(index + length)]))
            index += length
        }
        return out
    }

    private static func lz4BlockDecompress(_ src: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var index = 0

        while index < src.count {
            let token = src[index]
            index += 1

            var literal = Int(token >> 4)
            if literal == 15 {
                while index < src.count {
                    let value = Int(src[index]); index += 1
                    literal += value
                    if value != 255 { break }
                }
            }
            if literal > 0 {
                guard index + literal <= src.count else { return out }
                out += src[index..<(index + literal)]
                index += literal
            }

            if index + 2 > src.count { break }
            let offset = Int(src[index]) | (Int(src[index + 1]) << 8)
            index += 2
            guard offset > 0, offset <= out.count else { break }

            var match = Int(token & 0x0f)
            if match == 15 {
                while index < src.count {
                    let value = Int(src[index]); index += 1
                    match += value
                    if value != 255 { break }
                }
            }
            match += 4
            let start = out.count - offset
            for i in 0..<match {
                out.append(out[start + (i % offset)])
            }
        }
        return out
    }

    // MARK: - 业务级封装

    /// 请求体：urlencoded 文本 + "&"，再用固定密钥 AES 加密
    static func encryptBody(_ text: String) -> [UInt8] {
        aesEncrypt(Array(text.utf8) + [0x26])
    }

    /// 响应体：可能是明文 JSON，也可能是 AES（+ LZ4）
    static func decryptBody(_ data: [UInt8]) -> [UInt8]? {
        // 1) 先按明文 JSON 试
        if (try? JSONSerialization.jsonObject(with: Data(data))) != nil {
            return data
        }
        // 2) AES 解密；有些响应不压缩
        let decrypted = aesDecrypt(data)
        guard !decrypted.isEmpty else { return nil }
        if (try? JSONSerialization.jsonObject(with: Data(decrypted))) != nil {
            return decrypted
        }
        // 3) 标准情况：AES + LZ4
        let unpacked = lz4Decompress(decrypted)
        return unpacked.isEmpty ? nil : unpacked
    }

    // MARK: - 自检

    static func selfTest() -> [(String, Bool)] {
        var results: [(String, Bool)] = []

        let xorInput = Data(base64Encoded: "aGVsbG8gd29ybGQ=")!
        results.append(("XOR", xorBytes(Array(xorInput), xorKey).hex == "e5c0c9e1ca85fae2d7c9e9"))

        // 115 的 RSA 包装：先 XOR + 加 16 字节随机串，再按 128 字节分块加密
        results.append(("RSA",
                        rsaEncrypt(Array("test".utf8)) == "WJNN6mcQaph+4TaCC2aWJmvmiY1h80XhYLwe2Fdkpvv4qNdusoIYG7AIbJYLn6oynq2xt00VR0DPYd/if8nmrrOVjZa2EFdMlce1zsd8DcOPntHMdwM62e3xClh+BxVtdimeHWJ+YpyTw5/r6pMBedaOFAMYcZdaaL8poSpFAs8="))

        results.append(("AES", aesEncrypt(Array("hello".utf8)).hex == "91dbfb6164f41f09f939b39d50d3f757"))

        if let block = Data(base64Encoded: "b2hlbGxvIAYAQlBlbGxvIA=="),
           let expected = Data(base64Encoded: "aGVsbG8gaGVsbG8gaGVsbG8gaGVsbG8gaGVsbG8gaGVsbG8gaGVsbG8gaGVsbG8gaGVsbG8gaGVsbG8gaGVsbG8gaGVsbG8gaGVsbG8gaGVsbG8gaGVsbG8gaGVsbG8g") {
            // 115 的分帧格式：2 字节小端块长度 + 原始 LZ4 block
            var framed: [UInt8] = [UInt8(block.count & 0xff), UInt8((block.count >> 8) & 0xff)]
            framed += [UInt8](block)
            results.append(("LZ4", Data(lz4Decompress(framed)) == expected))
        } else {
            results.append(("LZ4", false))
        }

        return results
    }
}

extension Array where Element == UInt8 {
    init(hex: String) {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            bytes.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        self = bytes
    }

    var hex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
