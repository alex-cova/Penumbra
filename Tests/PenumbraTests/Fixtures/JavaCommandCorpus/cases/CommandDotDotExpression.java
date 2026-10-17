//! mode: dotDot
//! contains: Extract Variable…,Extract Field…,Extract Constant…,Surround With…
//! command: Extract Variable…
//! action: extractVariable
//! selects: user
package com.acme.cases;

class CommandDotDotExpression {
    void test(User user) {
        user../*|*/
    }
}
