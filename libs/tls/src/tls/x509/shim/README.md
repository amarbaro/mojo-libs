Temporary stand-in for lane 1 (SHA-2) and lane 2 (RSA/ECDSA verify, P-256 sign, bigint) so lane 3 builds and gates alone.
Ported from Mosaad-M/tls (MIT), import paths rewritten, nothing else changed. Only `x509/sigs.mojo` and `x509/key.mojo`
import from here. At integration: point those two files at `tls.sym` / `tls.asym` and delete this directory.
