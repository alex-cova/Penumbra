//! mode: readOnly
//! filter: def
//! contains: Go to Definition
//! excludes: Rename…,Extract Variable…
package com.acme.cases;

class ReadOnlyCommandFilter {
    void render(int width) {}

    void use() {
        this.re/*|*/nder(1);
    }
}
