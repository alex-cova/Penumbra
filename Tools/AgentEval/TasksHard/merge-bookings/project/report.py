from intervals import merge


def busy_hours(bookings):
    return sum(end - start for start, end in merge(bookings))
