def build(registry):
    registry.register("upper", str.upper)
    registry.register("strip", str.strip)


def run(registry, name, text):
    return registry.get(name)(text)
