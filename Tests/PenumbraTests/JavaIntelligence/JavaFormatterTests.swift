import XCTest
@testable import JavaIntelligence

final class JavaFormatterTests: XCTestCase {
    private func format(_ source: String, _ options: JavaFormattingOptions = JavaFormattingOptions()) -> String {
        JavaFormatter.format(source, options: options) ?? "<refused>"
    }

    private func assertFormats(_ input: String, to expected: String, file: StaticString = #filePath, line: UInt = #line) {
        let result = format(input)
        XCTAssertEqual(result, expected, file: file, line: line)
        // Formatting formatted code is a no-op.
        XCTAssertEqual(format(result), result, "not idempotent", file: file, line: line)
    }

    // MARK: - Indentation

    func testIndentsClassMembersAndBlocks() {
        assertFormats("""
        package demo;
        public class A {
        int x;
        void m() {
        if (x > 0) {
        x--;
        }
        }
        }
        """, to: """
        package demo;
        public class A {
            int x;
            void m() {
                if (x > 0) {
                    x--;
                }
            }
        }
        """)
    }

    func testTabIndentUnit() {
        let result = format("class A {\nvoid m() {\nint x;\n}\n}\n", JavaFormattingOptions(indentUnit: "\t"))
        XCTAssertEqual(result, "class A {\n\tvoid m() {\n\t\tint x;\n\t}\n}\n")
    }

    func testElseCatchFinallyAndDoWhileAlignWithTheirStatement() {
        assertFormats("""
        class A {
        void m() {
        if (a) {
        x();
        }
        else if (b) {
        y();
        }
        else {
        z();
        }
        try {
        f();
        }
        catch (Exception e) {
        g();
        }
        finally {
        h();
        }
        do {
        i();
        }
        while (c);
        }
        }
        """, to: """
        class A {
            void m() {
                if (a) {
                    x();
                }
                else if (b) {
                    y();
                }
                else {
                    z();
                }
                try {
                    f();
                }
                catch (Exception e) {
                    g();
                }
                finally {
                    h();
                }
                do {
                    i();
                }
                while (c);
            }
        }
        """)
    }

    func testAllmanBracesStayOnTheirOwnLineAlignedWithTheStatement() {
        assertFormats("""
        class A
        {
        void m()
        {
        if (a)
        {
        x();
        }
        }
        }
        """, to: """
        class A
        {
            void m()
            {
                if (a)
                {
                    x();
                }
            }
        }
        """)
    }

    func testSwitchIndentsCaseLabelsAndTheirStatements() {
        assertFormats("""
        class A {
        int m(int a) {
        switch (a) {
        case 1:
        foo();
        break;
        case 2: {
        bar();
        }
        break;
        default:
        baz();
        }
        return switch (a) {
        case 1 -> 10;
        case 2 -> {
        yield 20;
        }
        default -> 30;
        };
        }
        }
        """, to: """
        class A {
            int m(int a) {
                switch (a) {
                    case 1:
                        foo();
                        break;
                    case 2: {
                        bar();
                    }
                        break;
                    default:
                        baz();
                }
                return switch (a) {
                    case 1 -> 10;
                    case 2 -> {
                        yield 20;
                    }
                    default -> 30;
                };
            }
        }
        """)
    }

    func testWrappedLinesGetTwoLevelsOfContinuationIndent() {
        assertFormats("""
        class A {
        void m() {
        String s = first
        + second
        + third;
        list.stream()
        .filter(x -> x > 0)
        .forEach(System.out::println);
        call(a,
        b);
        if (a
        && b) {
        run();
        }
        }
        }
        """, to: """
        class A {
            void m() {
                String s = first
                        + second
                        + third;
                list.stream()
                        .filter(x -> x > 0)
                        .forEach(System.out::println);
                call(a,
                        b);
                if (a
                        && b) {
                    run();
                }
            }
        }
        """)
    }

    func testStatementsWithoutBracesAreOneLevelInAndWrappedOnesContinue() {
        assertFormats("""
        class A {
        void m() {
        if (a)
        x();
        else
        y();
        for (int i = 0; i < n; i++)
        sum +=
        i;
        while (b)
        if (c)
        z();
        outer:
        for (;;)
        break outer;
        }
        }
        """, to: """
        class A {
            void m() {
                if (a)
                    x();
                else
                    y();
                for (int i = 0; i < n; i++)
                    sum +=
                            i;
                while (b)
                    if (c)
                        z();
                outer:
                for (;;)
                    break outer;
            }
        }
        """)
    }

    func testLambdaBodiesAndAnonymousClassesIndentFromTheirOwnLine() {
        assertFormats("""
        class A {
        void m() {
        list.forEach(x -> {
        use(x);
        });
        foo.bar()
        .baz(x -> {
        use(x);
        });
        Runnable r = new Runnable() {
        public void run() {
        go();
        }
        };
        }
        }
        """, to: """
        class A {
            void m() {
                list.forEach(x -> {
                    use(x);
                });
                foo.bar()
                        .baz(x -> {
                            use(x);
                        });
                Runnable r = new Runnable() {
                    public void run() {
                        go();
                    }
                };
            }
        }
        """)
    }

    func testWrappedDeclarationHeaderDoesNotPushTheBodyIn() {
        assertFormats("""
        class A {
        void m(int a,
        int b) {
        run();
        }
        }
        """, to: """
        class A {
            void m(int a,
                    int b) {
                run();
            }
        }
        """)
    }

    func testAnnotationsOnTheLinesAboveAlignWithTheDeclaration() {
        assertFormats("""
        class A {
        @Override
        @SuppressWarnings("x")
        public String toString() {
        return "";
        }
        }
        """, to: """
        class A {
            @Override
            @SuppressWarnings("x")
            public String toString() {
                return "";
            }
        }
        """)
    }

    func testEnumsAndArrayInitializers() {
        assertFormats("""
        enum E {
        A(1),
        B(2);
        final int v;
        E(int v) {
        this.v = v;
        }
        }
        class B {
        int[] xs = {
        1,
        2
        };
        }
        """, to: """
        enum E {
            A(1),
            B(2);
            final int v;
            E(int v) {
                this.v = v;
            }
        }
        class B {
            int[] xs = {
                1,
                2
            };
        }
        """)
    }

    // MARK: - Spacing

    func testSpacingAroundOperatorsCommasKeywordsAndParentheses() {
        assertFormats("""
        class A{
        void m(int a,int b){
        int x=a+b*2;
        if(x>0&&a!=b){
        x+=1;
        }else{
        x-=1;
        }
        for(int i=0;i<10;i++){
        call( a , b );
        }
        while(x<3)x++;
        int y=cond?a:b;
        Function<String,Integer> f=s->s.length();
        }
        }
        """, to: """
        class A {
            void m(int a, int b) {
                int x = a + b * 2;
                if (x > 0 && a != b) {
                    x += 1;
                } else {
                    x -= 1;
                }
                for (int i = 0; i < 10; i++) {
                    call(a, b);
                }
                while (x < 3) x++;
                int y = cond ? a : b;
                Function<String, Integer> f = s -> s.length();
            }
        }
        """)
    }

    func testUnaryCastGenericAndArraySpacing() {
        assertFormats("""
        class A {
        void m() {
        int a=- b;
        boolean c=! d;
        i ++;
        -- j;
        String s=( String )o;
        List<String> l=new ArrayList<>();
        Map<String,List<Integer>> m=new HashMap<>();
        int[] arr=new int[ 3 ];
        int[] init=new int[]{1,2};
        Object x=Collections.<String>emptyList();
        String t=a.b ( ).c ( 1 );
        }
        }
        """, to: """
        class A {
            void m() {
                int a = -b;
                boolean c = !d;
                i++;
                --j;
                String s = (String) o;
                List<String> l = new ArrayList<>();
                Map<String, List<Integer>> m = new HashMap<>();
                int[] arr = new int[3];
                int[] init = new int[] {1, 2};
                Object x = Collections.<String>emptyList();
                String t = a.b().c(1);
            }
        }
        """)
    }

    func testGenericMethodsVarargsThrowsAndControlKeywordsBeforeParentheses() {
        assertFormats("""
        class A{
        public <T extends Comparable<T>> T max(T... xs) throws IOException,RuntimeException{
        synchronized(this){
        return(xs[0]);
        }
        }
        }
        """, to: """
        class A {
            public <T extends Comparable<T>> T max(T... xs) throws IOException, RuntimeException {
                synchronized (this) {
                    return (xs[0]);
                }
            }
        }
        """)
    }

    func testEmptyBodiesAndSingleLineBlocks() {
        assertFormats("""
        class A {
        void a(){ }
        void b() {return;}
        Runnable r=()->{};
        }
        """, to: """
        class A {
            void a() {}
            void b() { return; }
            Runnable r = () -> {};
        }
        """)
    }

    // MARK: - Things left alone

    func testStringsTextBlocksAndCommentsAreNeverEdited() {
        let source = "class A {\nString a = \"x   +   y\";\nString t = \"\"\"\n      keep   this\n   as is\n      \"\"\";\nint z = 1;   // trailing   comment\n/* a   b */ int w;\n}\n"
        XCTAssertEqual(format(source), "class A {\n    String a = \"x   +   y\";\n    String t = \"\"\"\n      keep   this\n   as is\n      \"\"\";\n    int z = 1;   // trailing   comment\n    /* a   b */ int w;\n}\n")
    }

    func testJavadocStarLinesAlignWithTheComment() {
        assertFormats("""
        class A {
        /**
        * Docs.
        *   Indented text.
        */
        void m() {}
        }
        """, to: """
        class A {
            /**
             * Docs.
             *   Indented text.
             */
            void m() {}
        }
        """)
    }

    func testTrailingWhitespaceBlankRunsAndFinalNewline() {
        let source = "class A {   \n\n\n\n\n    int x;\t\n}\n\n\n"
        XCTAssertEqual(format(source), "class A {\n\n\n    int x;\n}\n")
    }

    func testCRLFLineEndingsArePreserved() {
        let source = "class A {\r\nint x;\r\nvoid m() {\r\nx = 1;\r\n}\r\n}\r\n"
        XCTAssertEqual(format(source), "class A {\r\n    int x;\r\n    void m() {\r\n        x = 1;\r\n    }\r\n}\r\n")
    }

    func testRangeModeKeepsEveryLineBreak() {
        let source = "class A {\n\n\n\n\nint x;\n}\n"
        let result = format(source, JavaFormattingOptions(maxBlankLines: nil))
        XCTAssertEqual(result, "class A {\n\n\n\n\n    int x;\n}\n")
        XCTAssertEqual(result.components(separatedBy: "\n").count, source.components(separatedBy: "\n").count)
    }

    // MARK: - Refusals

    func testAFileWithASyntaxErrorIsRefused() {
        XCTAssertNil(JavaFormatter.format("class A { void m( { }\n"))
    }

    func testEmptyAndCommentOnlyFiles() {
        XCTAssertEqual(JavaFormatter.format(""), "")
        XCTAssertEqual(JavaFormatter.format("   // only a comment   \n"), "// only a comment   \n")
    }

    func testNonWhitespaceCharactersAreNeverChanged() {
        let source = """
        package a.b;
        import java.util.*;
        @SuppressWarnings({"a","b"}) public abstract class A<T extends Number&Comparable<T>> extends B implements C,D{
        private static final Map<String,List<? extends T>> M=new HashMap<>();
        static{ init(); }
        protected abstract <U> U convert(T t,U... rest) throws E;
        public void m(){ label: for(;;){ break label; } int[][] g={{1},{2,3}}; long l=1_000L<<2>>>1; var q=(Runnable & Serializable)()->{}; }
        }
        """
        let result = format(source)
        XCTAssertNotEqual(result, "<refused>")
        XCTAssertEqual(result.filter { !$0.isWhitespace }, source.filter { !$0.isWhitespace })
        XCTAssertEqual(format(result), result)
    }
}
