//! target: util/Strings.java:isBlank
package com.acme.cases;

import static com.acme.util.Strings.isBlank;

class StaticImportCall {
    boolean m(String s) { return /*|*/isBlank(s); }
}
