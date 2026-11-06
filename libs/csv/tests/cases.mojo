from test_golden import replay
from test_brute import run_brute
from test_lifetime import main as check_lifetime


def main() raises:
    replay()
    run_brute()
    check_lifetime()
    print("PASS cases")
