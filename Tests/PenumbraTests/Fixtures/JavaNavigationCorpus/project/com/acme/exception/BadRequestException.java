package com.acme.exception;

public class BadRequestException extends RuntimeException {
    private final int errorCode;

    public BadRequestException(String key, String message) {
        super(message);
        this.errorCode = 0;
    }

    public BadRequestException(String message, long errorCode) {
        super(message);
        this.errorCode = (int) errorCode;
    }

    public BadRequestException(String message, Exception cause) {
        super(message, cause);
        this.errorCode = 0;
    }

    public int getErrorCode() {
        return errorCode;
    }
}
