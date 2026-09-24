//! receiver: com.acme.model.Animal
//! contains: getSpecies, sound
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.function.*;
import java.util.stream.*;

class GenericBoundedTypeVar<T extends Animal> {
    void test(T pet) {
        pet./*|*/
    }
}
