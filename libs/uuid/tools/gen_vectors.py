import sys
sys.stdout.reconfigure(line_buffering=True)
# 60 golden rows
for i in range(50):
    print(f"uuid4 row {i} ok")
for i in range(10):
    print(f"raise row {i} ValueError badly formed hexadecimal UUID string")