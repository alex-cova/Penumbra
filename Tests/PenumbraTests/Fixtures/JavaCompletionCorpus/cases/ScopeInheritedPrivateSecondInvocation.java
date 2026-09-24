//! invocation: 2
//! contains: secretAge, species
package com.acme.cases;

import com.acme.model.*;

class ScopeInheritedPrivateSecondInvocation extends Animal {
    public String sound() {
        int x = s/*|*/
        return "";
    }
}
