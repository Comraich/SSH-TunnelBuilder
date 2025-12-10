import UIKit

class ExampleViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        
        let oidString = "1.2.3.4"
        _ = OID(oidString) // changed from `let oid = OID(oidString)`
        
        let value = "42"
        _ = Int(value) // changed from `let intValue = Int(value)`
    }
}

struct OID {
    let value: String
    init(_ value: String) {
        self.value = value
    }
}
