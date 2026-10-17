//! mode: dotDot
//! contains: Extract Variable…
//! excludes: Go to Definition,Rename…
package com.acme.cases;

class CommandDotDotFilter {
    void test(User user) {
        user..ex/*|*/
    }
}
