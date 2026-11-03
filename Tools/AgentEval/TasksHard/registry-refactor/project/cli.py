import plugins


def available():
    return ", ".join(plugins.names())
