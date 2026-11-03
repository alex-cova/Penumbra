from intervals import merge

DAY_START = 9
DAY_END = 17


def free_slots(bookings):
    """Free (start, end) gaps inside the working day, in hours."""
    free = []
    cursor = DAY_START
    for start, end in merge(bookings):
        if start > cursor:
            free.append((cursor, start))
        cursor = end
    if cursor < DAY_END:
        free.append((cursor, DAY_END))
    return free
