import TreeSitter

/// Opaque reference to a Tree-sitter language grammar.
///
/// `TSLanguage` is forward-declared in the C API and is not imported into Swift
/// on current toolchains, so callers use `OpaquePointer` instead.
public typealias TreeSitterLanguagePointer = OpaquePointer

extension TSInputEncoding {
    /// UTF-16 encoding used by `NSString` on macOS.
    static var treeSitterUTF16: TSInputEncoding {
        switch String.preferredUTF16Encoding {
        case .utf16LittleEndian:
            TSInputEncodingUTF16LE
        case .utf16BigEndian:
            TSInputEncodingUTF16BE
        default:
            TSInputEncodingUTF16LE
        }
    }
}

extension TreeSitterLanguagePointer {
    public init<T>(_ pointer: UnsafePointer<T>) {
        self = OpaquePointer(UnsafeRawPointer(pointer))
    }

    public init?<T>(_ pointer: UnsafePointer<T>?) {
        guard let pointer else {
            return nil
        }
        self.init(pointer)
    }
}
