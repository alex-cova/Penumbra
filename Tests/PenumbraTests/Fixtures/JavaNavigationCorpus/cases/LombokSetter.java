//! target: lombok/Person.java:age
package com.acme.cases;

import com.acme.lombok.Person;

class LombokSetter {
    void m(Person p) { p./*|*/setAge(3); }
}
