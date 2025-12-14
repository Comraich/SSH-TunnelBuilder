import XCTest
import NIO
import NIOSSH

@testable import OpenSSHKeyParser

final class OpenSSHKeyParserTests: XCTestCase {
    
    func testNormalizeScalar() {
        // Scalars to test: ASCII character, non-ASCII BMP, and surrogate pair
        let asciiScalar = Unicode.Scalar("A")!
        let bmpScalar = Unicode.Scalar(0x03A9)! // Greek Capital Letter Omega
        // Swift does not allow creating surrogate pair scalars directly
        // but we can test a scalar in supplementary planes
        let supplementaryScalar = Unicode.Scalar(0x1F600)! // 😀 Emoji
        
        XCTAssertEqual(OpenSSHKeyParser.normalizeScalar(asciiScalar), asciiScalar)
        XCTAssertEqual(OpenSSHKeyParser.normalizeScalar(bmpScalar), bmpScalar)
        // For supplementaryScalar, normalizeScalar returns replacement scalar
        XCTAssertEqual(OpenSSHKeyParser.normalizeScalar(supplementaryScalar), "\u{FFFD}".unicodeScalars.first!)
    }
    
    func testReadSSHBytesLengthHandling() throws {
        var buffer = ByteBuffer()
        
        // Write a 4-byte length prefix with value 5 and 5 bytes of data
        buffer.writeInteger(UInt32(5))
        buffer.writeString("hello")
        
        // Should succeed and read "hello"
        let bytes = try OpenSSHKeyParser.readSSHBytes(&buffer)
        XCTAssertEqual(bytes, Array("hello".utf8))
        
        // Now test with shorter data than length prefix
        buffer.clear()
        buffer.writeInteger(UInt32(5))
        buffer.writeString("hey")
        XCTAssertThrowsError(try OpenSSHKeyParser.readSSHBytes(&buffer)) { error in
            XCTAssertTrue(error is OpenSSHKeyParser.ParseError)
        }
        
        // Test with empty buffer
        var emptyBuffer = ByteBuffer()
        XCTAssertThrowsError(try OpenSSHKeyParser.readSSHBytes(&emptyBuffer)) { error in
            XCTAssertTrue(error is OpenSSHKeyParser.ParseError)
        }
    }
    
    func testExtractOpenSSHDataMinimalPEM() throws {
        let pem = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAABAAAAgQAAAAMAAAABAAAABg==
        -----END OPENSSH PRIVATE KEY-----
        """
        let pemData = pem.data(using: .utf8)!
        let extracted = try OpenSSHKeyParser.extractOpenSSHData(from: pemData)
        // The extracted data should be the base64-decoded content between the headers
        let expectedBase64 = "b3BlbnNzaC1rZXktdjEAAAABAAAAgQAAAAMAAAABAAAABg=="
        let expectedData = Data(base64Encoded: expectedBase64)!
        XCTAssertEqual(extracted, expectedData)
        
        // Test with missing headers
        let invalidPem = "No headers here"
        let invalidPemData = invalidPem.data(using: .utf8)!
        XCTAssertThrowsError(try OpenSSHKeyParser.extractOpenSSHData(from: invalidPemData)) { error in
            XCTAssertTrue(error is OpenSSHKeyParser.ParseError)
        }
    }
    
    func testParseOpenSSHPrivateKeyInvalidHeaderThrows() {
        let invalidPEM = """
        -----BEGIN INVALID HEADER-----
        b3BlbnNzaC1rZXktdjEAAAABAAAAgQAAAAMAAAABAAAABg==
        -----END INVALID HEADER-----
        """
        let invalidData = invalidPEM.data(using: .utf8)!
        
        XCTAssertThrowsError(try OpenSSHKeyParser.parseOpenSSHPrivateKey(from: invalidData)) { error in
            XCTAssertTrue(error is OpenSSHKeyParser.ParseError)
        }
    }
    
    static var allTests = [
        ("testNormalizeScalar", testNormalizeScalar),
        ("testReadSSHBytesLengthHandling", testReadSSHBytesLengthHandling),
        ("testExtractOpenSSHDataMinimalPEM", testExtractOpenSSHDataMinimalPEM),
        ("testParseOpenSSHPrivateKeyInvalidHeaderThrows", testParseOpenSSHPrivateKeyInvalidHeaderThrows),
    ]
}
