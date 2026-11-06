from uuid import UUID

def main():
    var state: UInt128 = 0x123456789abcdef0fedcba9876543210
    var hex = "0123456789abcdef"
    for _ in range(256):
        state = state * UInt128(6364136223846793005) + 1442695040888963407
        var value = UUID(state)
        var le = value.bytes_le()
        var text = String()
        for b in le:
            text += hex[byte=Int(b >> 4)]
            text += hex[byte=Int(b & 15)]
        print(value.__str__(), "|", value.hex(), "|", text, "|", value.clock_seq(), "|", value.node(), "|", value.__hash__(), sep="")
