from collections import OrderedDict


class TTLCache:
    """Least-recently-used cache whose entries expire `ttl` seconds after they were last written."""

    def __init__(self, capacity, ttl, clock):
        self.capacity = capacity
        self.ttl = ttl
        self.clock = clock
        self._data = OrderedDict()  # key -> (value, expires_at), oldest use first

    def delete(self, key):
        self._data.pop(key, None)


    def get(self, key, default=None):
        item = self._data.get(key)
        if item is None:
            return default
        value, expires_at = item
        if self.clock.now() > expires_at:
            del self._data[key]
            return default
        return value

    def set(self, key, value):
        if key in self._data:
            _, expires_at = self._data[key]
            self._data[key] = (value, expires_at)
            return
        if len(self._data) >= self.capacity:
            self._data.popitem(last=False)
        self._data[key] = (value, self.clock.now() + self.ttl)
