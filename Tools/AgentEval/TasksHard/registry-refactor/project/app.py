import plugins


def build():
    plugins.register("upper", str.upper)
    plugins.register("strip", str.strip)


def run(name, text):
    return plugins.get(name)(text)
