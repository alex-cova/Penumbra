package com.acme.model;

import java.util.List;
import java.util.Optional;

/** A registered user. */
public class User implements Named, Comparable<User> {
    private final String id;
    private String name;
    private Address address;
    private List<Role> roles;
    protected int loginCount;
    int packageCounter;
    public static final String ANONYMOUS = "anonymous";

    public User(String id, String name) {
        this.id = id;
        this.name = name;
    }

    public String getId() { return id; }
    @Override
    public String getName() { return name; }
    public void setName(String name) { this.name = name; }
    public Address getAddress() { return address; }
    public Optional<Address> findAddress() { return Optional.ofNullable(address); }
    public List<Role> getRoles() { return roles; }
    public boolean isActive() { return true; }
    public int getAge() { return 0; }
    @Deprecated
    public String getLegacyName() { return name; }
    private void secretHelper() { }
    public static User anonymous() { return new User(ANONYMOUS, ANONYMOUS); }

    @Override
    public int compareTo(User other) { return name.compareTo(other.name); }

    /** Nested type used through inheritance. */
    public static class Builder {
        public Builder withName(String name) { return this; }
        public User build() { return null; }
    }
}
