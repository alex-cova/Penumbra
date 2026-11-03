import time


class Clock:
    def now(self):
        return time.monotonic()


class FakeClock:
    def __init__(self):
        self.t = 0.0

    def now(self):
        return self.t

    def advance(self, seconds):
        self.t += seconds
