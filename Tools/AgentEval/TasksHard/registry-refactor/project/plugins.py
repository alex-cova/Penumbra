_registry = {}


def register(name, fn):
    _registry[name] = fn


def get(name):
    return _registry[name]


def names():
    return sorted(_registry)
