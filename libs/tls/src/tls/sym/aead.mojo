"""The AEAD shape the record layers use: in place, 12-byte nonce, 16-byte tag."""


trait Aead:
    def seal(self, nonce: Span[UInt8, ImmutAnyOrigin], aad: Span[UInt8, ImmutAnyOrigin], mut buf: List[UInt8]) raises:
        """Encrypt buf in place and append the 16-byte tag."""
        ...

    def open(self, nonce: Span[UInt8, ImmutAnyOrigin], aad: Span[UInt8, ImmutAnyOrigin], mut buf: List[UInt8]) raises:
        """Check the tag (constant time) before touching the data, then decrypt in place and drop the tag.
        On a bad tag raise and leave buf unchanged."""
        ...

    def wipe(mut self):
        """Zero the key material (best effort)."""
        ...
