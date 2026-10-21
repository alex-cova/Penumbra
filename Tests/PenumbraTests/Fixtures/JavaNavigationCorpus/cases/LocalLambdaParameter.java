//! target: self:x
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import com.acme.util.Strings;
import java.util.*;
import java.util.function.*;

class LocalLambdaParameter {
    void m(List<Dog> dogs) { dogs.forEach(x -> /*|*/x.speak()); }
}
