import Foundation

/// The Sunflower (FernflowerKit) license, shown before Umbra decompiles a `.class` file.
/// Sunflower is MIT-licensed; the notice has to be visible to the person using it.
public enum JavaDecompilerAgreement {
    public static let title = "Sunflower user agreement"

    public static let text = """
    Umbra decompiles .class files that have no attached Java source using Sunflower (FernflowerKit). The result is reconstructed from bytecode. It is not the original source, and it can be incomplete or wrong.

    Sunflower is free software under the MIT License:

    MIT License

    Copyright (c) 2026 Alex Cova

    Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
    """

    /// Prepended to every decompiled buffer so the copyright notice stays with the copy.
    public static let sourceNotice = """
    // Decompiled from .class bytecode by Sunflower (FernflowerKit).
    // This is not the original source.
    // Sunflower — MIT License — Copyright (c) 2026 Alex Cova.
    """
}
