/**
 * A label in the layered graph structure.
 */
package final class LLabel: LShape {

    package var text: String

    package override init() {
        self.text = ""
        super.init()
    }

    package init(_ thetext: String) {
        self.text = thetext
        super.init()
    }

    package func getText() -> String {
        return text
    }

    package func setText(_ text: String) {
        self.text = text
    }

    package override func getDesignation() -> String? {
        if !text.isEmpty {
            return text
        }
        return super.getDesignation()
    }

    package func toString() -> String {
        if let designation = getDesignation() {
            return "l_\(designation)"
        }
        return "label"
    }
}
