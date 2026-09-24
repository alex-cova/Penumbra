//! contains: species
//! top1: species
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.function.*;
import java.util.stream.*;

class ScopeInheritedField extends Animal {
    public String sound() {
        return spec/*|*/
    }
}
