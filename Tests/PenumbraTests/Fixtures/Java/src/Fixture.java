package com.penumbra.fixture;

import java.util.List;
import java.util.Map;

/**
 * A javadoc comment on the class.
 */
public class Fixture<T extends Comparable<T>> extends AbstractFixture implements java.io.Serializable {

    public static final int CONSTANT = 42;
    private String name;
    protected List<T> items;

    public Fixture() {
    }

    /**
     * A javadoc comment on the constructor.
     */
    public Fixture(String name, List<T> items) {
        this.name = name;
        this.items = items;
    }

    /**
     * A javadoc comment on the method.
     * @param a first
     * @param b second
     * @return the sum
     */
    public int add(int a, int b) {
        return a + b;
    }

    public Map<String, List<T>> group(T key, int... counts) {
        return null;
    }

    @Deprecated
    public void oldMethod() {
    }

    @Override
    void doWork() {
    }

    public static Fixture<String> create() {
        return new Fixture<>();
    }

    public enum Kind {
        FIRST, SECOND
    }

    public interface Listener {
        void onEvent(String name);
    }

    public static class Nested {
        public int value;
    }

    public record Point(int x, int y) {
    }
}
