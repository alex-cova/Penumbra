"""Input validators for the signup form."""


def validate_email(value):
    text = str(value).strip()
    text = " ".join(text.split())
    text = text.lower()
    if text.count("@") != 1 or " " in text:
        raise ValueError("invalid email")
    local, domain = text.split("@")
    if not local or "." not in domain:
        raise ValueError("invalid email")
    return text


def validate_username(value):
    text = str(value).strip()
    text = " ".join(text.split())
    text = text.lower()
    if not 3 <= len(text) <= 20 or not text.replace("_", "").replace(" ", "").isalnum():
        raise ValueError("invalid username")
    return text


def validate_tag(value):
    text = str(value).strip()
    text = " ".join(text.split())
    text = text.lower()
    if not text or len(text) > 30:
        raise ValueError("invalid tag")
    return text
