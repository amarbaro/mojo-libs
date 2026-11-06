"""Replay every RFC final UUID through its generator and its textual parser."""
from uuid import UUID, UUIDError, uuid3, uuid5, uuid6, uuid8, NAMESPACE_DNS, NAMESPACE_URL, NAMESPACE_OID, NAMESPACE_X500, NIL, MAX
from uuid import _uuid4_from, _uuid7_from
from support import check

def golden_tests() raises:
    var text = String()
    with open("tests/golden/rfc9562.txt", "r") as f:
        text = f.read()
    var count = 0
    for line in text.split("\n"):
        if line.byte_length() == 0:
            continue
        var row = line.split("|")
        var section = String(row[0])
        var expected = String(row[1]).lower()
        var value = materialize[NIL]()
        var dns = materialize[NAMESPACE_DNS]()
        if section == "A.2":  # RFC 9562 Appendix A.2, DNS + www.example.com
            value = uuid3(dns, "www.example.com")
        elif section == "A.3":  # RFC 9562 Appendix A.3, original random bytes
            value = _uuid4_from(UUID("919108F752D133205BACF847DB4148A8").bytes())
        elif section == "A.4":  # RFC 9562 Appendix A.4, DNS + www.example.com
            value = uuid5(dns, "www.example.com")
        elif section == "A.5":  # RFC 9562 Appendix A.5, timestamp + clock_seq + node
            value = uuid6(0x9f6bdeced846, 0x33c8, 1645557742000000000)
        elif section == "A.6":  # RFC 9562 Appendix A.6, exact rand_a/rand_b
            value = _uuid7_from(1645557742000, (UInt64(0xcc3) << 30) | 0x18c4dc0c, 0x0c07398f)
        elif section == "B.1":  # RFC 9562 Appendix B.1, custom_a/b/c
            value = uuid8(0x2489e9ad2ee2, 0xe00, 0xec932d5f69181c0)
        elif section == "B.2":  # RFC 9562 Appendix B.2, SHA-256 custom blocks
            value = uuid8(0x5c146b143c52, 0xafd, 0x138a375d0df1fbf6)
        elif section == "6.6.DNS":  # RFC 9562 Section 6.6, Table 3
            value = dns
        elif section == "6.6.URL":  # RFC 9562 Section 6.6, Table 3
            value = materialize[NAMESPACE_URL]()
        elif section == "6.6.OID":  # RFC 9562 Section 6.6, Table 3
            value = materialize[NAMESPACE_OID]()
        elif section == "6.6.X500":  # RFC 9562 Section 6.6, Table 3
            value = materialize[NAMESPACE_X500]()
        elif section == "5.9":  # RFC 9562 Section 5.9, Nil
            value = materialize[NIL]()
        elif section == "5.10":  # RFC 9562 Section 5.10, Max
            value = materialize[MAX]()
        else:
            raise Error("unknown RFC fixture " + section)
        check(value.__str__() == expected, "RFC 9562 " + section + ": " + value.__str__())
        check(UUID(String(row[1])).int() == value.int(), "RFC parse " + section)
        count += 1
    check(count == 13, "missing RFC fixture")
    print("PASS RFC 9562: 13 complete vectors")

def main() raises:
    golden_tests()
