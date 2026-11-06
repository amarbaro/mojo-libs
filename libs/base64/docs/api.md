# API

- b64encode(s: Span) -> List[Byte]: encode base64.
- b64encode_into(s, mut out): append encoded.
- b64decode(s, altchars, validate) -> List[Byte]: decode base64.
- b64decode_into(s, mut out, altchars, validate).
- standard_b64encode(s) -> List[Byte].
- standard_b64encode_into(s, mut out).
- standard_b64decode(s, validate) -> List[Byte].
- standard_b64decode_into(s, mut out, validate).
- urlsafe_b64encode(s) -> List[Byte].
- urlsafe_b64encode_into(s, mut out).
- urlsafe_b64decode(s, validate) -> List[Byte].
- urlsafe_b64decode_into(s, mut out, validate).
- b32encode(s) -> List[Byte].
- b32encode_into(s, mut out).
- b32decode(s, casefold, map01) -> List[Byte].
- b32decode_into(s, mut out, casefold, map01).
- b32hexencode(s) -> List[Byte].
- b32hexencode_into(s, mut out).
- b32hexdecode(s, casefold) -> List[Byte].
- b32hexdecode_into(s, mut out, casefold).
- b16encode(s) -> List[Byte].
- b16encode_into(s, mut out).
- b16decode(s, casefold) -> List[Byte].
- b16decode_into(s, mut out, casefold).

Raises ValueError/Error text matching CPython on invalid input.
All inputs Span[Byte]; altchars empty means None.
