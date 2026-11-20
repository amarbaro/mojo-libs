"""String.find and rfind as an Int: -1 when absent. Mojo 1.2 returns Int, nightly returns Optional[Int]."""


def pos_of(r: Int) -> Int:
    return r


def pos_of(r: Optional[Int]) -> Int:
    return r.or_else(-1)
