//! target: lombok/Person.java:name
package com.acme.cases;

import com.acme.lombok.Person;

class LombokGetter {
    String m(Person p) { return p./*|*/getName(); }
}
