class UserService:
    def __init__(self, store, cache):
        self.store = store
        self.cache = cache

    def get(self, user_id):
        user = self.cache.get(user_id)
        if user is None:
            user = self.store[user_id]
            self.cache.set(user_id, user)
        return user

    def rename(self, user_id, name):
        self.store[user_id] = {**self.store[user_id], "name": name}
