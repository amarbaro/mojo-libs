import struct, sys, xml.etree.ElementTree as ET
png, xml = sys.argv[1], sys.argv[2]
with open(png, 'rb') as f:
    h = f.read(24)
assert h[:8] == b'\x89PNG\r\n\x1a\n', 'FAIL not png'
w, hh = struct.unpack('>II', h[16:24])
assert (w, hh) == (1200, 2608), f'FAIL size {w}x{hh}'
root = ET.parse(xml).getroot()
assert root.tag == 'hierarchy', 'FAIL no hierarchy'
assert root.get('rotation') == '0', 'FAIL rotation'
print(f'PASS png {w}x{hh} xml hierarchy rotation=0 nodes={sum(1 for _ in root.iter("node"))}')
