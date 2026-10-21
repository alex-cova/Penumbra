//! package-dirs: com/acme/util
package com.acme.cases;

class PackageQualifiedLeaf {
    boolean m(String s) { return com.acme./*|*/util.Strings.isBlank(s); }
}
