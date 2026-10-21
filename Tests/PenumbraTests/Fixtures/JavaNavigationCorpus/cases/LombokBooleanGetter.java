//! target: lombok/Person.java:active
package com.acme.cases;

import com.acme.lombok.Person;

class LombokBooleanGetter {
    boolean m(Person p) { return p./*|*/isActive(); }
}
