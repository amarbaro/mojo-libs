import re, sys, xml.etree.ElementTree as ET
# usage: annotate_xml.py DUMP.xml > OUT.tsv   (read-only: parses an existing uiautomator dump)
src = sys.argv[1]
root = ET.parse(src).getroot()
print('idx\tclass\ttext\tdesc\tclickable\tx1\ty1\tx2\ty2')
for i, n in enumerate(root.iter('node')):
    m = re.fullmatch(r'\[(\d+),(\d+)\]\[(\d+),(\d+)\]', n.get('bounds', ''))
    if not m:
        continue
    x1, y1, x2, y2 = map(int, m.groups())
    txt = (n.get('text') or '').replace('\t', ' ').replace('\n', ' ')
    dsc = (n.get('content-desc') or '').replace('\t', ' ').replace('\n', ' ')
    cls = (n.get('class') or '').rsplit('.', 1)[-1]
    print(f"{i}\t{cls}\t{txt}\t{dsc}\t{n.get('clickable')}\t{x1}\t{y1}\t{x2}\t{y2}")
