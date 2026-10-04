"""A tiny stock keeper."""


class Inventory:
    def __init__(self):
        self._stock = {}

    def add(self, sku, quantity):
        if quantity <= 0:
            raise ValueError("quantity must be positive")
        self._stock[sku] = self._stock.get(sku, 0) + quantity

    def remove(self, sku, quantity):
        """Takes `quantity` units out of stock; refuses to go below zero."""
        if quantity <= 0:
            raise ValueError("quantity must be positive")
        have = self._stock.get(sku, 0)
        if quantity > have:
            raise ValueError("not enough stock for %s" % sku)
        self._stock[sku] = have - quantity

    def quantity(self, sku):
        return self._stock.get(sku, 0)

    def low_stock(self, threshold):
        """SKUs with `threshold` units or fewer, sorted by SKU."""
        return sorted(sku for sku, have in self._stock.items() if have <= threshold)

    def total_units(self):
        return sum(self._stock.values())
