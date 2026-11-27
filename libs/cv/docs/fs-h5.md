# fs-h5 captures and licence table (H5, P0)

Shoot list: a private 194-photo shoot, one absolute path per line sorted by the timestamp in the filename (IMG_ and MVIMG_ prefixes merged); it is not in the repo, pass your own list to tests/listing.sh.
Phone captures: adb exec-out screencap + uiautomator dump, current screen only (no navigation, read-only).
- 0123456789ABCDEF (A70): PNG ok; uiautomator dump 33 bytes, likely a failed dump (BLOCK for UI tree).
- R5CTB2LHPDE (SM_F721B): PNG and XML ok.
- 192.168.178.42:37465 (SM_A217F, wifi): PNG and XML ok.
- 6d344501 (Xiaomi nezha, 25128PNA1C, MIUI home, 1200x2608, rotation 0): PNG and XML ok; trailing "UI hierchary dumped" notice stripped (dump writes it to /dev/tty).
Screens: 1 per phone, not 3 home/settings screens: navigation needs input, outside read-only scope (BLOCK for 2 of 3 per phone).
CDP: see cdp-manifest.tsv. Tab AF85319C (Phone Panel, 71 elements) persisted as cdp-snap-AF85319C-phonepanel.txt. Gate H5-phone6d: tools/fs-h5/check_phone6d.py.
GUI licences: ../../.work/fs/licences/gui.tsv; terms and download URLs UNVERIFIED (no card or web fetch this phase); no download done.
Paper check: 23 of 23 plan-cited GUI ids present in titles-gui-agents-20261123.tsv and in txt/; no cards exist yet (CARD PENDING).

## P2 repairs and annotations (H5, fs/p2-h5)

- R5CTB2LHPDE PNG: adb warning text (347 bytes, "[Warning] Multiple displays...") was prefixed to the capture. Stripped; the
  PNG now decodes (PIL, 1080x2640 RGBA) and every chunk CRC passes. Broken hash 05568bcf...; repaired b58904d1c4278decdd54888e6082748d542b29261ebeaa796cb6bab15060b7da.
  Pixels are the device capture; check_phone6d.py is Xiaomi-only (1200x2608), so it fails on this file by design.
- R5CTB2LHPDE XML: trailing "UI hierchary dumped to: /dev/tty" (33 bytes) stripped; parses as hierarchy.
- annot-6d344501.tsv, annot-R5CTB2LHPDE.tsv: element boxes, text, desc, clickable from the existing dumps (tools/fs-h5/annotate_xml.py). Read-only: no device contact.
- ScreenSpot split manifest: BLOCK. No ScreenSpot data on disk (no download this phase; licence UNVERIFIED). No manifest written.
