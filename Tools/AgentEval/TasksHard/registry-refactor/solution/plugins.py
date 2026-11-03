class Registry:
    def __init__(self):
        self._fns = {}

    def register(self, name, fn):
        self._fns[name] = fn

    def get(self, name):
        return self._fns[name]

    def names(self):
        return sorted(self._fns)
