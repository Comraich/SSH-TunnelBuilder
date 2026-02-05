//import Testing
//import NIO
//import NIOSSH
//
//@testable import SSH_TunnelBuilder
//
//class OpenSSHKeyParserTests: XCTestCase {
//    func testReadingSSHBytesHandlesCorrectAndIncorrectLengths() throws {
//        var buffer = ByteBuffer()
//
//        // Test case: successful read
//        buffer.writeInteger(UInt32(5))
//        buffer.writeString("hello")
//        let bytes = try OpenSSHKeyParser.readSSHBytes(from: &buffer)
//        XCTAssertEqual(bytes, Array("hello".utf8))
//
//        // Test case: data shorter than length prefix should throw
//        buffer.clear()
//        buffer.writeInteger(UInt32(5))
//        buffer.writeString("hey")
//        XCTAssertThrowsError(try OpenSSHKeyParser.readSSHBytes(from: &buffer))
//
//        // Test case: empty buffer should throw
//        var emptyBuffer = ByteBuffer()
//        XCTAssertThrowsError(try OpenSSHKeyParser.readSSHBytes(from: &emptyBuffer))
//    }
//
//    func testExtractingOpenSSHDataFromPEMValidatesHeaders() throws {
//        let pem = """
//        -----BEGIN OPENSSH PRIVATE KEY-----
//        b3BlbnNzaC1rZXktdjEAAAABAAAAgQAAAAMAAAABAAAABg==
//        -----END OPENSSH PRIVATE KEY-----
//        """
//        let extracted = try OpenSSHKeyParser.extractOpenSSHData(from: pem)
//
//        let expectedBase64 = "b3BlbnNzaC1rZXktdjEAAAABAAAAgQAAAAMAAAABAAAABg=="
//        let expectedData = try XCTUnwrap(Data(base64Encoded: expectedBase64))
//        XCTAssertEqual(extracted, expectedData)
//
//        // Test with missing headers, which should throw an error
//        let invalidPem = "No headers here"
//        XCTAssertThrowsError(try OpenSSHKeyParser.extractOpenSSHData(from: invalidPem))
//    }
//
//    func testParsingPrivateKeyWithInvalidMagicHeaderThrowsError() {
//        // This data is missing the required "openssh-key-v1\0" magic header.
//        let invalidHeaderData = Data("invalid-header-and-some-more-bytes-to-read".utf8)
//        XCTAssertThrowsError(try OpenSSHKeyParser.parseOpenSSHPrivateKey(invalidHeaderData))
//    }
//}
