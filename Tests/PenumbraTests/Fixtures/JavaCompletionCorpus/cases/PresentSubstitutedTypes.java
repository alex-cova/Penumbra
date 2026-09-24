//! shows: findById -> Optional<User> | Repository; findByName -> List<User> | -; save -> User | Repository
package com.acme.cases;

import com.acme.model.*;
import java.util.*;

class PresentSubstitutedTypes {
    void test(List<User> users, UserRepository repository) {
        users.get(0);
        repository./*|*/
    }
}
