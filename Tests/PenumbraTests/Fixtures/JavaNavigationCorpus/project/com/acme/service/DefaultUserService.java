package com.acme.service;

import com.acme.model.User;

public class DefaultUserService implements UserService {
    @Override
    public User find(String id) {
        return User.of(id);
    }
}
