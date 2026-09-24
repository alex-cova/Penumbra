package com.acme.model;

public class Address {
    private String city;
    private String street;
    private int zip;

    public String getCity() { return city; }
    public String getStreet() { return street; }
    public int getZip() { return zip; }
    public Country getCountry() { return null; }
}
