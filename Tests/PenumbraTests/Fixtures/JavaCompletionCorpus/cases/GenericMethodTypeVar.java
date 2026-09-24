//! receiver: com.acme.model.Animal
//! contains: getSpecies
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import java.util.*;
import java.util.function.*;
import java.util.stream.*;

class GenericMethodTypeVar {
    <A extends Animal> void test(A pet) {
        pet./*|*/
    }
}
