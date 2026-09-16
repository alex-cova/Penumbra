import Foundation

/**
 * A runtime exception that can be used to wrap checked exceptions. Use this where it is
 * appropriate to forward an error to the next point where it can be handled (i.e. displayed
 * to the user) without the need to explicitly declare the error in every method signature.
 */
package class WrappedException: RuntimeException {

    /** the serial version UID. */
    package static let serialVersionUID: Int64 = -1630132187697677735

    package var cause: Error?

    /**
     * Create a wrapped exception.
     *
     * @param cause the error that caused this exception
     */
    package init(cause: Error) {
        self.cause = cause
        super.init(cause.localizedDescription)
    }

    /**
     * Create a wrapped exception with additional message.
     *
     * @param message an additional message for information
     * @param cause the error that caused this exception
     */
    package init(message: String, cause: Error) {
        self.cause = cause
        super.init(message)
    }

}

