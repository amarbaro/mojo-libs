"""Row binary for tests/supervision/cases/dataset_s3_voc.txt (build/dataset_s3_voc)."""
from supervision.dataset.rowds import run


def main() raises:
    run("s3voc")
