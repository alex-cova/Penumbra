//! mode: dotDot
//! accepts: Extract Variable…
//! acceptAction: extractVariable
//! acceptSelects: name
//! yields: String name = "x"; name
package com.acme.cases;

class CommandDotDotAccept {
    void test() {
        String name = "x"; name../*|*/
    }
}
