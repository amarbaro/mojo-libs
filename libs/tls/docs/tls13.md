# TLS 1.3 (lane 4): `src/tls/tls13/`

Sans-IO TLS 1.3 client and server: bytes in, bytes and events out, no sockets. 1500 lines of code by `mokei`
(`src/tls/tls13/*.mojo` without `_tmp_crypto/`). Gate: `tests/gate.sh [--mutants]`.

## Files

| File | What |
|---|---|
| `wire.mojo` | `bad(alert_name, what)` errors, alert names and codes, `put*`, `Rd` bounds-checked reader, `ct_equal`, `wipe` |
| `keysched.mojo` | `KeySchedule(h)` early/handshake/master, `expand_label`, traffic key/iv, `finished_mac`, `cv_content`, `next_secret` (KeyUpdate), suite table |
| `record.mojo` | `Cipher` (one direction: nonce, in-place AEAD seal into the output buffer, open, padding strip, limits), `RecordReader`, `seal_all` |
| `messages.mojo` | `Hello` (ClientHello, ServerHello, HRR), `Ext` list, typed extension builders and parsers, EE, Certificate, CertificateVerify, Finished, `Ticket`, KeyUpdate, CertificateRequest |
| `conn.mojo` | `Conn`: shared by both roles. Handshake reassembly, transcript, alerts, KeyUpdate, key limit, wipe. `Out` result struct |
| `client.mojo` | `Client13[V: Verifier]`, `default_hello`, `kex_public`, `kex_shared`, `pad_hello` |
| `server.mojo` | `Server13[S: Signer]`, `ServerConfig` |
| `verify.mojo` | traits `Verifier` and `Signer` (the seams to lanes 2 and 3), `NoVerify` (tests only) |
| `_tmp_crypto/` | TEMPORARY port from Mosaad-M-tls (MIT, notice in `LICENSE-Mosaad-M-tls`). Wave 2 replaces it |

## Use

```mojo
# client: the caller supplies randomness (hello random, session id, x25519 and P-256 private keys)
var h = default_hello(host, random32, session_id32, x25519_public_key(xpriv), [String("http/1.1")])
var c = Client13[MyVerifier](h, host, xpriv, ppriv, MyVerifier(...))
send(c.start())                       # ClientHello record
var o = c.feed(Span(bytes_from_peer)) # o.send -> peer, o.data = application data, o.events, o.error
if o.has(EV_DONE): send(c.write(request))
# server
var cfg = ServerConfig(server_random32, xpriv, ppriv)   # cfg.suites, groups, alpn, cookie, rsl, ee_exts
var s = Server13[MySigner](cfg^, MySigner(...))
var o = s.feed(Span(bytes_from_peer))   # s.sni, s.alpn, s.group, s.c.suite after the handshake
```

Events: `EV_DONE`, `EV_CLOSE` (peer close_notify, ours is queued in `o.send`), `EV_KEYUPDATE`, `EV_TICKET`, `EV_ERROR`.
A fatal error never raises: `o.error` names it (`tls: <alert>: <what>`), the alert is already in `o.send`, keys are
zeroed, later input is ignored. A peer's fatal alert gives `tls: peer_alert: <name>` and no alert goes back.
`c.write(data)`, `c.key_update()`, `c.close()` return bytes to send. `c.c.key_limit` (default 2^24 records) triggers an
automatic KeyUpdate in `write`.

## Behaviour that is fixed (checked by a gate)

- Records: header checked before the body is buffered (type, 0x03xx, length <= 2^14+256), unprotected record after the
  keys are installed is `unexpected_message` (except the compatibility CCS), inner type = last non-zero byte, send limit
  from the peer's `record_size_limit`, receive limit from ours, sequence number never wraps.
- Handshake: messages reassembled across records (cap 64 KiB), key changes only at record boundaries, strict order,
  duplicate extension is `illegal_parameter`, certificate chain cap 10, Finished compared in constant time,
  CertificateVerify content built here, `rsa_pkcs1` refused for CertificateVerify.
- HelloRetryRequest both ways: `message_hash` transcript, share replaced in place, cookie, ClientHello padding to 512,
  server checks that ClientHello 2 equals ClientHello 1 except share, cookie, padding.
- Compatibility mode: session id echo, one CCS each way, CCS after the handshake is rejected.
- KeyUpdate: answered under the old key, `update_requested` answered once, KeyUpdate not alone in its record rejected.
- Session tickets: client keeps at most 8, no resumption yet. The server sends none.

## Seams to the other lanes

`Verifier.verify(chain, scheme, signed, sig, host)` raises `tls: bad_certificate: ...`. Lane 3 chain validation plus lane 2
signature check implement it. `Signer.schemes() / chain() / sign(scheme, content)` is lane 2 signing (ECDSA P-256,
RSA-PSS) plus lane 3 key loading. Replacing `_tmp_crypto`: the call sites are `keysched.mojo` (hash, hmac, hkdf),
`record.mojo` (`GcmKey.seal_into/open_into`, `chacha20_poly1305_seal_into/open_into`: 2 call sites each) and
`client.mojo` (`x25519_public_key`, `x25519_shared`, `p256_public_key`, `p256_ecdh`).

## Interface changes against `docs/api.md`

- `KeySchedule[H]` is `KeySchedule(h: Int)` with the hash length (32 or 48) at run time; the transcript is kept as bytes
  in `Conn` and hashed on demand (one code path for SHA-256 and SHA-384).
- Errors are `Error("tls: <alert_name>: <what>")` (a superset of `tls: <what>`); `wire.alert_of` maps them to codes.
- `Client13` and `Server13` are generic over `Verifier` / `Signer` (new traits in `verify.mojo`); randomness and ephemeral
  private keys are constructor inputs, so the machines are deterministic and testable.
- `Record` is `Cipher` + `RecordReader`; the AEAD is pointer based and in place (`seal_into`), not `seal(nonce, aad, mut pt)`.
- `feed` returns `Out` (send, data, events, error) instead of a tuple.

## Open items

tlsfuzzer is not installed here (not run). PSK/resumption, 0-RTT, client certificates (client answers a
CertificateRequest with an empty Certificate), ML-KEM hybrid share (an incoming 1216-byte share is skipped), a
TLS 1.2 fallback decision (lane 5: a ServerHello without `supported_versions` gives `protocol_version`).
Speed is in `tests/bench_tls13.mojo`; the ported ChaCha20 (2.2 GB/s against openssl 4.8) and x25519 (163 us against 33 us)
are lane 1-2 work.
