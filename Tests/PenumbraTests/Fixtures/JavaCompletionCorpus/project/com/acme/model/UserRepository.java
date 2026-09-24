package com.acme.model;

import java.util.List;

public interface UserRepository extends Repository<User, String> {
    List<User> findByName(String name);
    User findByEmail(String email);
}
