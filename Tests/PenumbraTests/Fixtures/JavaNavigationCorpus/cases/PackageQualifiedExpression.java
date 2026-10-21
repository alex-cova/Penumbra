//! package-dirs: com/acme
package com.acme.cases;

class PackageQualifiedExpression {
    boolean m(String s) { return com./*|*/acme.util.Strings.isBlank(s); }
}
