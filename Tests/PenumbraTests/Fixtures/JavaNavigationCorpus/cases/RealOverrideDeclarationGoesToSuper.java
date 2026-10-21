//! target: generic/Repository.java:findById
package com.acme.cases;

import com.acme.model.*;
import com.acme.service.*;
import com.acme.util.Strings;
import com.acme.exception.BadRequestException;
import com.acme.generic.*;
import java.util.*;
import java.util.stream.*;
import java.util.function.*;

class RealOverrideDeclarationGoesToSuper {
    static class Dir implements Repository<User, String> {
        @Override public Optional<User> /*|*/findById(String id) { return Optional.empty(); }
        public List<User> findAll() { return List.of(); }
        public User save(User u) { return u; }
    }
}
