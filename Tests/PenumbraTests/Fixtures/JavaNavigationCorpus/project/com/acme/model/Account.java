package com.acme.model;

public class Account {
    private final String owner;
    private final int balance;

    private Account(Builder builder) {
        this.owner = builder.owner;
        this.balance = builder.balance;
    }

    public static Builder builder() {
        return new Builder();
    }

    public String getOwner() {
        return owner;
    }

    public int getBalance() {
        return balance;
    }

    public static class Builder {
        private String owner;
        private int balance;

        public Builder owner(String owner) {
            this.owner = owner;
            return this;
        }

        public Builder balance(int balance) {
            this.balance = balance;
            return this;
        }

        public Account build() {
            return new Account(this);
        }
    }
}
