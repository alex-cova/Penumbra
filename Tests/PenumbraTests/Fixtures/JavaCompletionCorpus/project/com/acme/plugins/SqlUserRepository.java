package com.acme.plugins;

import com.acme.model.User;
import com.acme.model.UserRepository;
import java.util.List;
import java.util.Optional;

public class SqlUserRepository implements UserRepository {
    public Optional<User> findById(String id) { return Optional.empty(); }
    public List<User> findAll() { return List.of(); }
    public User save(User entity) { return entity; }
    public void delete(User entity) {}
    public long count() { return 0; }
    public List<User> findByName(String name) { return List.of(); }
    public User findByEmail(String email) { return null; }
}
