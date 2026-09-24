//! excludes: secretAge
//! contains: species
package com.acme.cases;

import com.acme.model.*;

class ScopeInheritedPrivateHidden extends Animal {
    public String sound() {
        int x = s/*|*/
        return "";
    }
}
