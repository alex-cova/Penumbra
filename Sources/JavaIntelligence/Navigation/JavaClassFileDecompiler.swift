import Foundation
import FernflowerKit

/// Decompiles a `.class` file the user opened directly (from the Explorer, Finder or a jar's row),
/// rather than one the index resolved for Go to Definition. The caller must already have shown
/// ``JavaDecompilerAgreement``.
///
/// A tab showing the result keeps the `.class` file's URL. ``JavaAttachedSources/isExtractedSource(_:)``
/// treats such a URL as dependency code, so the tab is read-only and nothing checks it.
public enum JavaClassFileDecompiler {
    /// Whether `url` names a `.class` file.
    public static func isClassFile(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "class"
    }

    /// `CAFEBABE`, the first four bytes of every class file. A file called `x.class` that does not
    /// start with it is not bytecode and is left to the ordinary hex or text routing.
    public static func hasClassMagic(_ head: Data) -> Bool {
        head.count >= 4 && head.prefix(4).elementsEqual([0xCA, 0xFE, 0xBA, 0xBE])
    }

    /// Java source for `classData`, led by the decompiler notice, or `nil` when the bytes do not
    /// parse as a class or Sunflower cannot handle them.
    public static func decompile(_ classData: Data) -> String? {
        guard hasClassMagic(classData),
              let raw = try? JavaDecompiler().decompile(classData: classData) else { return nil }
        var source = raw
        // A nested class (`Outer$Inner.class`) is printed as `Outer.Inner`; normalise it the way
        // Go to Definition does, so the file reads as one declaration.
        if let stub = try? ClassFileReader.read(classData, origin: .jar(URL(fileURLWithPath: "/"))) {
            source = JavaClassDecompiler.normalizeTypeName(
                raw, simpleName: stub.simpleName, dottedName: JavaClassDecompiler.dottedName(of: stub)
            )
        }
        return JavaDecompilerAgreement.sourceNotice + "\n\n" + source
    }

    /// Reads and decompiles the file at `url`.
    public static func decompile(contentsOf url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return decompile(data)
    }
}
