"""Offline differential oracle against stdlib uuid, never writes RFC fixtures."""
import sys
import uuid
sys.stdout.reconfigure(line_buffering=True)
state = 0x123456789ABCDEF0FEDCBA9876543210
for _ in range(256):
    state = (state * 6364136223846793005 + 1442695040888963407) & ((1 << 128) - 1)
    value = uuid.UUID(int=state)
    print(str(value), value.hex, value.bytes_le.hex(), value.clock_seq, value.node, hash(value), sep="|")
