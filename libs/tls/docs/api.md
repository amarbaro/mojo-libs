# API

The public surface of `tls`, by layer. `tls.sym` and `tls.asym` re-export their names (`from tls.sym import sha256`); the other layers import from the module file, for example `from tls.x509.chain import verify_chain` or `from tls.tls13.client import Client13`.

All bytes are `List[UInt8]` in, `Span[UInt8, _]` for read-only views. Errors raise `Error("tls: <what>")`.

## `tls.sym`
- `sha256(data) -> List[UInt8]`, `sha384(data)`, `sha512(data)`; streaming `Sha256`, `Sha384`, `Sha512` with `update(data)`, `digest()` (trait `Hash`)
- `hmac[H](key, data) -> List[UInt8]` (H = `Sha256` | `Sha384`, for example `hmac[Sha256](key, data)`)
- `hkdf_extract[H](salt, ikm)`, `hkdf_expand[H](prk, info, n)`, `hkdf_expand_label[H](secret, label, context, n)` (RFC 8446 7.1)
- `prf12[H](secret, label, seed, n)` (RFC 5246 5)
- `wipe(buf)`: zero a buffer
- Trait `Aead`, implemented by `AesGcm(key)` and `ChaCha20Poly1305(key)`: `seal(nonce, aad, mut buf) raises` encrypts `buf` in place and appends the tag, `open(nonce, aad, mut buf) raises` checks the tag in constant time, then decrypts in place and drops it
- Building blocks: `Aes(key)`, `chacha20_xor`, `poly1305_mac`

## `tls.asym`
- `x25519(scalar32, point32) -> List[UInt8]`, `x25519_base(scalar32)`; `x448(scalar56, point56)`, `x448_base(scalar56)`
- `P256Key`: `generate()` (from a CSPRNG), `public_bytes()` (uncompressed), `ecdh(peer_uncompressed) -> shared32`, `sign_sha256(msg_hash32) -> DER signature`, `zeroize()`
- `p256_verify(pub, hash, der_sig) -> Bool`, `p384_verify(...)`, `p384_sign(d48, hash48) -> der` (RFC 6979 with HMAC-SHA-384), `p384_public(d)`, `p384_ecdh(d, peer)`
- `RsaPublic`: `verify_pkcs1(hash_alg, hash, sig)`, `verify_pss(hash_alg, hash, sig)`; `RsaPrivate`: `sign_pss(hash_alg, hash) -> sig` (CRT + blinding), `sign_pkcs1(hash_alg, hash)`, `public()`, `zeroize()`; `rsa_d_ok(n, e, d)`
- `random_bytes(n)` from `getrandom(2)`

## `tls.x509`
- `tls.x509.der`: `Der(bytes)` with `next()`, `seq()`, `int_bytes()`, `oid()`, `bits()`, `octets()`, `time()`, `peek()`, `done()`
- `tls.x509.pem`: `pem_blocks(text) -> List[PemBlock]`, each with `label` and `der`
- `tls.x509.cert`: `Certificate.parse(der)`: subject/issuer raw names, SAN dns/ip, not_before/after, public key (kind + bytes), basic_constraints, key_usage, eku, tbs bytes, signature alg + value
- `tls.x509.chain`: `verify_chain(chain: List[Certificate], host, now, roots, client=False) raises` (`client=True` checks client-auth rules and skips the host name), `load_system_roots()`, `load_roots_pem(text, mut dropped)`
- `tls.x509.key`: `load_private_key(pem) -> PrivateKey` (P-256, P-384 or RSA), `load_private_key_der(der)`, `load_private_key_file(path)`

## `tls.tls13`
- `Cipher` (one direction, in-place AEAD) and `RecordReader` over a byte stream
- message codecs (`tls.tls13.messages`): `Hello` (ClientHello, ServerHello, HelloRetryRequest), extensions, EncryptedExtensions, Certificate, CertificateVerify, Finished, `Ticket` (NewSessionTicket), KeyUpdate, CertificateRequest
- `KeySchedule(h)`: early, handshake, application secrets, traffic keys/ivs, finished keys, with `h` the hash length (32 or 48)
- `Client13[V: Verifier]`, `Server13[S: Signer]` state machines (sans-IO, no sockets): `feed(bytes) -> Out`; `Out` holds `send`, `data`, `events` and `error`; events are `EV_DONE`, `EV_CLOSE`, `EV_KEYUPDATE`, `EV_TICKET`, `EV_ERROR`
- Traits `Verifier` and `Signer` (`tls.tls13.verify`) supply certificate checks and signing; `NoVerify` is for tests only

## `tls.tls12` and `tls.net`
- `Client12[C: Crypto12]`, `Server12[C: Crypto12]`: sans-IO, but `feed(bytes) raises` returns nothing; read the output with `cn.take_output()` and the application data with `cn.take_app()`, write with `cn.write_app(data)`, close with `cn.close()`. `RealCrypto` (`tls.tls12.realcrypto`) is the shipped `Crypto12`
- `TlsConfig` (certs per SNI name, ALPN list, `tls12` and `require_client_cert` switches, timeouts, limits), `TlsServer` on mojo-aio (nonblocking, per-connection buffers, timeouts; `run(handler)` or `step(handler)`), `TlsStream` read/write for blocking clients, `tls_connect[C](host, port, alpn, addr)`
