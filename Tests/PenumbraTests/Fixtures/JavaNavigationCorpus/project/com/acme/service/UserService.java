package com.acme.service;

import com.acme.model.User;

public interface UserService {
    User find(String id);

    default User first() {
        return find("1");
    }
}
