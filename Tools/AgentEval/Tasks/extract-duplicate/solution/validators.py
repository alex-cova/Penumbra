"""Input validators for the signup form."""


def _normalize(value):
    text = str(value).strip()
    text = " ".join(text.split())
    text = text.lower()
    return text


def validate_email(value):
    text = _normalize(value)
    if text.count("@") != 1 or " " in text:
        raise ValueError("invalid email")
    local, domain = text.split("@")
    if not local or "." not in domain:
        raise ValueError("invalid email")
    return text


def validate_username(value):
    text = _normalize(value)
    if not 3 <= len(text) <= 20 or not text.replace("_", "").replace(" ", "").isalnum():
        raise ValueError("invalid username")
    return text


def validate_tag(value):
    text = _normalize(value)
    if not text or len(text) > 30:
        raise ValueError("invalid tag")
    return text
