import XCTest
@testable import JavaIntelligence

final class GenericSignatureParserTests: XCTestCase {
    func testSimpleGenericSuperclass() {
        // class Foo extends ArrayList<String>
        let sig = GenericSignatureParser.parseClassSignature("Ljava/util/ArrayList<Ljava/lang/String;>;")
        let result = try? XCTUnwrap(sig)
        XCTAssertEqual(result?.typeParameters, [])
        guard case .classType(let name, let args, _) = result?.superclass else {
            return XCTFail("expected classType superclass")
        }
        XCTAssertEqual(name, "java.util.ArrayList")
        XCTAssertEqual(args.count, 1)
        if case .type(let t) = args[0] {
            XCTAssertEqual(t.erasedQualifiedName, "java.lang.String")
        } else {
            XCTFail("expected concrete type argument")
        }
    }

    func testTypeParametersWithBoundAndInterfaces() {
        // class Foo<T extends Comparable<T>> extends Object implements Serializable, Cloneable
        let sig = "<T:Ljava/lang/Comparable<TT;>;>Ljava/lang/Object;Ljava/io/Serializable;Ljava/lang/Cloneable;"
        let result = try! XCTUnwrap(GenericSignatureParser.parseClassSignature(sig))
        XCTAssertEqual(result.typeParameters.count, 1)
        XCTAssertEqual(result.typeParameters[0].name, "T")
        XCTAssertEqual(result.typeParameters[0].bounds.first?.erasedQualifiedName, "java.lang.Comparable")
        XCTAssertEqual(result.superclass.erasedQualifiedName, "java.lang.Object")
        XCTAssertEqual(result.interfaces.map(\.erasedQualifiedName), ["java.io.Serializable", "java.lang.Cloneable"])
    }

    func testInterfaceOnlyBound() {
        // <T:Ljava/lang/Object;:Ljava/lang/Runnable;> -- an empty class bound followed by an interface bound.
        let sig = "<T::Ljava/lang/Runnable;>Ljava/lang/Object;"
        let result = try! XCTUnwrap(GenericSignatureParser.parseClassSignature(sig))
        XCTAssertEqual(result.typeParameters.count, 1)
        XCTAssertEqual(result.typeParameters[0].bounds.map(\.erasedQualifiedName), ["java.lang.Runnable"])
    }

    func testMethodSignatureWithGenericsAndThrows() {
        // <T:Ljava/lang/Object;>(TT;I)Ljava/util/List<TT;>;^Ljava/io/IOException;
        let sig = "<T:Ljava/lang/Object;>(TT;I)Ljava/util/List<TT;>;^Ljava/io/IOException;"
        let result = try! XCTUnwrap(GenericSignatureParser.parseMethodSignature(sig))
        XCTAssertEqual(result.typeParameters.map(\.name), ["T"])
        XCTAssertEqual(result.parameters.count, 2)
        XCTAssertEqual(result.parameters[0], .typeVariable(name: "T"))
        XCTAssertEqual(result.parameters[1], .primitive(.int))
        guard case .classType(let name, let args, _) = result.returnType else {
            return XCTFail("expected List<T> return type")
        }
        XCTAssertEqual(name, "java.util.List")
        XCTAssertEqual(args.count, 1)
        XCTAssertEqual(result.thrownTypes.map(\.erasedQualifiedName), ["java.io.IOException"])
    }

    func testWildcardBounds() {
        // Ljava/util/List<+Ljava/lang/Number;>; and <-Ljava/lang/Number;> and <*>
        let extendsSig = try! XCTUnwrap(GenericSignatureParser.parseClassSignature("Ljava/util/List<+Ljava/lang/Number;>;"))
        guard case .classType(_, let extendsArgs, _) = extendsSig.superclass,
              case .wildcard(.extends(let bound)) = extendsArgs.first else {
            return XCTFail("expected ? extends Number")
        }
        XCTAssertEqual(bound.erasedQualifiedName, "java.lang.Number")

        let superSig = try! XCTUnwrap(GenericSignatureParser.parseClassSignature("Ljava/util/List<-Ljava/lang/Number;>;"))
        guard case .classType(_, let superArgs, _) = superSig.superclass,
              case .wildcard(.superBound(let bound)) = superArgs.first else {
            return XCTFail("expected ? super Number")
        }
        XCTAssertEqual(bound.erasedQualifiedName, "java.lang.Number")

        let unboundedSig = try! XCTUnwrap(GenericSignatureParser.parseClassSignature("Ljava/util/List<*>;"))
        guard case .classType(_, let unboundedArgs, _) = unboundedSig.superclass else {
            return XCTFail("expected List<?>")
        }
        XCTAssertEqual(unboundedArgs.first, .wildcard(nil))
    }

    func testNestedTypeQualification() {
        // Outer<T>.Inner<U> -- a non-static nested type reference with its own type argument.
        let sig = "Lcom/example/Outer<Ljava/lang/String;>.Inner<Ljava/lang/Integer;>;"
        let result = try! XCTUnwrap(GenericSignatureParser.parseClassSignature(sig))
        guard case .classType(let name, let args, let outer) = result.superclass else {
            return XCTFail("expected nested classType")
        }
        XCTAssertEqual(name, "com.example.Outer.Inner")
        XCTAssertEqual(args.count, 1)
        guard case .classType(let outerName, _, _) = outer else {
            return XCTFail("expected outer type reference")
        }
        XCTAssertEqual(outerName, "com.example.Outer")
    }

    func testArrayTypeInSignature() {
        let sig = "(Ljava/lang/String;)[I"
        let result = try! XCTUnwrap(GenericSignatureParser.parseMethodSignature(sig))
        guard case .array(let element) = result.returnType else {
            return XCTFail("expected int[] return type")
        }
        XCTAssertEqual(element, .primitive(.int))
    }

    func testMalformedSignatureReturnsNil() {
        XCTAssertNil(GenericSignatureParser.parseClassSignature("garbage"))
        XCTAssertNil(GenericSignatureParser.parseMethodSignature("not-a-signature"))
    }
}
