//! receiver: com.acme.cases.VisibilityProtectedSubclass
//! contains: breathe
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.function.*;
import java.util.stream.*;

class VisibilityProtectedSubclass extends Animal {
    public String sound() {
        this.bre/*|*/
        return "";
    }
}
