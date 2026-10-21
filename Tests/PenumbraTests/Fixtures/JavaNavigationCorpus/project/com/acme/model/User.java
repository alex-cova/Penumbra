package com.acme.model;

public class User {
    private String name;
    private Role role;

    public String getName() {
        return name;
    }

    public Role getRole() {
        return role;
    }

    public static User of(String name) {
        User user = new User();
        user.name = name;
        return user;
    }
}
