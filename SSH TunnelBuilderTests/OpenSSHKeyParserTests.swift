import Testing
import Foundation
import NIO
import NIOSSH

@testable import SSH_TunnelBuilder

@Suite("OpenSSHKeyParser Tests")
struct OpenSSHKeyParserTests {
    @Test("Reading SSH bytes handles correct and incorrect lengths")
    func readSSHBytesLengthHandling() throws {
        var buffer = ByteBuffer()

        // Test case: successful read
        buffer.writeInteger(UInt32(5))
        buffer.writeString("hello")
        let bytes = try OpenSSHKeyParser.readSSHBytes(from: &buffer)
        #expect(bytes == Array("hello".utf8))

        // Test case: data shorter than length prefix should throw
        buffer.clear()
        buffer.writeInteger(UInt32(5))
        buffer.writeString("hey")
        #expect(throws: OpenSSHKeyParser.OpenSSHParsingError.insufficientData) {
            _ = try OpenSSHKeyParser.readSSHBytes(from: &buffer)
        }

        // Test case: empty buffer should throw
        var emptyBuffer = ByteBuffer()
        #expect(throws: OpenSSHKeyParser.OpenSSHParsingError.insufficientData) {
            _ = try OpenSSHKeyParser.readSSHBytes(from: &emptyBuffer)
        }
    }

    @Test("Extracting OpenSSH data from PEM validates headers")
    func extractOpenSSHDataMinimalPEMAndHeaderValidation() throws {
        let pem = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAABAAAAgQAAAAMAAAABAAAABg==
        -----END OPENSSH PRIVATE KEY-----
        """
        let extracted = try OpenSSHKeyParser.extractOpenSSHData(from: pem)

        let expectedBase64 = "b3BlbnNzaC1rZXktdjEAAAABAAAAgQAAAAMAAAABAAAABg=="
        let expectedData = try #require(Data(base64Encoded: expectedBase64))
        #expect(extracted == expectedData)

        // Test with missing headers, which should throw an error
        let invalidPem = "No headers here"
        #expect(throws: OpenSSHKeyParser.OpenSSHParsingError.invalidPEMFormat) {
            _ = try OpenSSHKeyParser.extractOpenSSHData(from: invalidPem)
        }
    }

    @Test("Parsing private key data with an invalid magic header throws an error")
    func parseOpenSSHPrivateKeyWithInvalidHeader() {
        // This data is missing the required "openssh-key-v1\0" magic header.
        let invalidHeaderData = Data("invalid-header-and-some-more-bytes-to-read".utf8)
        #expect(throws: OpenSSHKeyParser.OpenSSHParsingError.invalidKeyFormat(reason: "Invalid OpenSSH magic header")) {
            _ = try OpenSSHKeyParser.parseOpenSSHPrivateKey(invalidHeaderData)
        }
    }
}

