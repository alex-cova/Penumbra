package com.acme.service;

import com.acme.model.User;
import com.acme.model.UserRepository;
import java.util.List;
import java.util.Map;

public class UserService {
    private final UserRepository repository;

    public UserService(UserRepository repository) { this.repository = repository; }

    public User findUser(String id) { return null; }
    public User findUser(String firstName, String lastName) { return null; }
    public List<User> findAll() { return repository.findAll(); }
    public Map<String, User> byId() { return null; }
    public void register(User user) { }
    public void notify(User user, String message) { }
    public int count(Long since) { return 0; }
    public String describe(Object value) { return ""; }
    public String describe(Integer value) { return ""; }
    public UserRepository getRepository() { return repository; }
    public com.acme.model.Address locate(Object key) { return null; }
    public User locate(String id) { return null; }
    public com.acme.model.Role locate(int code) { return null; }
    public com.acme.model.Country locate(String first, String... rest) { return null; }
    public com.acme.model.Dog adopt(com.acme.model.Animal animal) { return null; }
    public com.acme.model.Address adopt(com.acme.model.Named named) { return null; }
}
