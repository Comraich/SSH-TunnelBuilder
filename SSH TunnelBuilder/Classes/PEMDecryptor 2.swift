import Foundation

struct ASN1Reader {
    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = data
        self.offset = 0
    }

    mutating func readSequence() -> Data {
        // Implementation detail: read sequence header and return sequence data
        // Advance offset accordingly
        return Data()
    }

    mutating func readObjectIdentifier() -> String {
        // Implementation detail: read OID
        return ""
    }

    mutating func readOctetString() -> Data {
        // Implementation detail: read octet string
        return Data()
    }

    mutating func readInteger() -> Int {
        // Implementation detail: read integer value
        return 0
    }

    mutating func advance(_ count: Int) {
        offset += count
    }
}

func parseASN1Data(_ data: Data) {
    var asn1 = ASN1Reader(data)
    let sequenceData = asn1.readSequence()

    var innerASN1 = ASN1Reader(sequenceData)
    _ = innerASN1.readSequence()

    var oidASN1 = ASN1Reader(innerASN1.readOctetString())
    let oid = oidASN1.readObjectIdentifier()

    var paramsASN1 = ASN1Reader(innerASN1.readOctetString())
    _ = paramsASN1.readSequence()

    var intASN1 = ASN1Reader(paramsASN1.readOctetString())
    let intValue = intASN1.readInteger()
}
