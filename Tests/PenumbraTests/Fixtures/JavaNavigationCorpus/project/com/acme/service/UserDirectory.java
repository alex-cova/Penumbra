package com.acme.service;

import com.acme.generic.BaseService;
import com.acme.generic.Repository;
import com.acme.model.User;
import java.util.List;
import java.util.Optional;

public class UserDirectory extends BaseService<User> implements Repository<User, String> {
    @Override
    public Optional<User> findById(String id) {
        return Optional.of(User.of(id));
    }

    @Override
    public List<User> findAll() {
        return all();
    }

    @Override
    public User save(User entity) {
        return super.save(entity);
    }
}
