# fs-h5 captures and licence table (H5, P0)

Shoot list: shoot-194.list, 194 files, sorted by timestamp in filename (IMG_ and MVIMG_ prefixes merged). Source: ebay.de/.work/stock-20261122/work/.
Phone captures: adb exec-out screencap + uiautomator dump, current screen only (no navigation, read-only).
- 0123456789ABCDEF (A70): PNG ok; uiautomator dump 33 bytes, likely a failed dump (BLOCK for UI tree).
- R5CTB2LHPDE (SM_F721B): PNG and XML ok.
- 192.168.178.42:37465 (SM_A217F, wifi): PNG and XML ok.
- 6d344501 (Xiaomi nezha, 25128PNA1C, MIUI home, 1200x2608, rotation 0): PNG and XML ok; trailing "UI hierchary dumped" notice stripped (dump writes it to /dev/tty).
Screens: 1 per phone, not 3 home/settings screens: navigation needs input, outside read-only scope (BLOCK for 2 of 3 per phone).
CDP: see cdp-manifest.tsv. Tab AF85319C (Phone Panel, 71 elements) persisted as cdp-snap-AF85319C-phonepanel.txt. Gate H5-phone6d: tools/fs-h5/check_phone6d.py.
GUI licences: ../../.work/fs/licences/gui.tsv; terms and download URLs UNVERIFIED (no card or web fetch this phase); no download done.
Paper check: 23 of 23 plan-cited GUI ids present in titles-gui-agents-20261123.tsv and in txt/; no cards exist yet (CARD PENDING).
