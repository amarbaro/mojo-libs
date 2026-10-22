"""HTTP/1.x messages: an incremental request parser and a response encoder. No sockets here.

The grammar follows h11 (the oracle, see tools/http_oracle.py): single-space request line, token method and
header names, no space before the colon, Content-Length digits only, `Transfer-Encoding: chunked` or nothing.
Stricter than h11 on purpose where leniency enables request smuggling: bare LF and obsolete line folding are
400, and Content-Length with Transfer-Encoding is 400.
"""

comptime SP: UInt8 = 32
comptime HT: UInt8 = 9
comptime CR: UInt8 = 13
comptime LF: UInt8 = 10
comptime COLON: UInt8 = 58


struct Limits(Copyable, Movable):
    var max_head: Int  # request line + headers, bytes; over it: 431
    var max_body: Int  # decoded body, bytes; over it: 413

    def __init__(out self, max_head: Int = 16384, max_body: Int = 1 << 20):
        self.max_head = max_head
        self.max_body = max_body


struct Request(Copyable, Movable):
    var method: String
    var target: String
    var path: String  # target up to '?'
    var query: String  # after '?', without it
    var minor: Int  # HTTP/1.minor
    var names: List[String]  # lower-case, in arrival order
    var values: List[String]
    var body: List[UInt8]

    def __init__(out self):
        self.method = ""
        self.target = ""
        self.path = ""
        self.query = ""
        self.minor = 1
        self.names = List[String]()
        self.values = List[String]()
        self.body = List[UInt8]()

    def header(self, name: String) -> String:
        """The first value of the header `name` (lower-case); "" when absent."""
        for i in range(len(self.names)):
            if self.names[i] == name:
                return self.values[i]
        return ""

    def has(self, name: String) -> Bool:
        for i in range(len(self.names)):
            if self.names[i] == name:
                return True
        return False

    def keep_alive(self) -> Bool:
        """Whether the connection stays open after the response: HTTP/1.1 unless `Connection: close`,
        HTTP/1.0 only with `Connection: keep-alive`."""
        var c = self.connection()
        if self.minor == 0:
            return c == "keep-alive"
        return c != "close"

    def connection(self) -> String:
        """The Connection tokens lower-cased, comma-joined with no spaces ("close" wins over the rest)."""
        var out = String()
        for i in range(len(self.names)):
            if self.names[i] == "connection":
                for t in self.values[i].split(","):
                    var tok = String(t.strip()).lower()
                    if tok == "close":
                        return "close"
                    if tok == "keep-alive":
                        out = "keep-alive"
        return out


struct Parsed(Copyable, Movable):
    """The outcome of parse_request. `status` != 0: reject with it. Else `used` = 0 needs more bytes,
    `used` > 0 is the length of the finished request. `cont`: a 100-continue is owed (head complete,
    body not yet)."""

    var used: Int
    var status: Int
    var cont: Bool

    def __init__(out self, used: Int = 0, status: Int = 0, cont: Bool = False):
        self.used = used
        self.status = status
        self.cont = cont


@always_inline
def _token(c: UInt8) -> Bool:
    if (c >= 48 and c <= 57) or (c >= 65 and c <= 90) or (c >= 97 and c <= 122):
        return True
    return c == 33 or c == 35 or c == 36 or c == 37 or c == 38 or c == 39 or c == 42 or c == 43 or c == 45 or c == 46 or c == 94 or c == 95 or c == 96 or c == 124 or c == 126


def _str(b: Span[UInt8, _], lo: Int, hi: Int) -> String:
    return String(unsafe_from_utf8=b[lo:hi])


def _find_crlf(b: Span[UInt8, _], at: Int, end: Int) -> Int:
    """Index of the CR of the first CRLF in [at, end), or -1."""
    var i = at
    while i + 1 < end:
        if b[i] == CR and b[i + 1] == LF:
            return i
        i += 1
    return -1


def _hex(c: UInt8) -> Int:
    if c >= 48 and c <= 57:
        return Int(c) - 48
    if c >= 97 and c <= 102:
        return Int(c) - 87
    if c >= 65 and c <= 70:
        return Int(c) - 55
    return -1


def _digits(s: String) -> Int:
    """The value of a non-empty all-digit string; -1 when it is anything else or past 18 digits."""
    if s.byte_length() == 0 or s.byte_length() > 18:
        return -1
    var n = 0
    for c in s.as_bytes():
        if c < 48 or c > 57:
            return -1
        n = n * 10 + Int(c) - 48
    return n


def _head_end(b: Span[UInt8, _], limit: Int) -> Int:
    """Index just past the first CRLFCRLF within the first `limit` bytes, or -1."""
    var n = min(len(b), limit)
    for i in range(n - 3):
        if b[i] == CR and b[i + 1] == LF and b[i + 2] == CR and b[i + 3] == LF:
            return i + 4
    return -1


def _request_line(b: Span[UInt8, _], lo: Int, hi: Int, mut req: Request) -> Int:
    """Fill method, target, minor from b[lo:hi]; 0 on success or the status to reject with."""
    var i = lo
    while i < hi and _token(b[i]):
        i += 1
    if i == lo or i >= hi or b[i] != SP:
        return 400
    req.method = _str(b, lo, i)
    i += 1
    var t = i
    while i < hi and b[i] > 32 and b[i] < 127:
        i += 1
    if i == t or i >= hi or b[i] != SP:
        return 400
    req.target = _str(b, t, i)
    i += 1
    if hi - i != 8 or _str(b, i, i + 5) != "HTTP/" or b[i + 6] != 46 or b[i + 5] < 48 or b[i + 5] > 57 or b[i + 7] < 48 or b[i + 7] > 57:
        return 400
    if b[i + 5] != 49:
        return 505
    req.minor = 0 if b[i + 7] == 48 else 1
    return 0


def _header_line(b: Span[UInt8, _], lo: Int, hi: Int, mut req: Request) -> Int:
    """Append the header in b[lo:hi]; 0 on success or the status to reject with."""
    if b[lo] == SP or b[lo] == HT:
        return 400  # obsolete line folding
    var i = lo
    while i < hi and _token(b[i]):
        i += 1
    if i == lo or i >= hi or b[i] != COLON:
        return 400
    var name = _str(b, lo, i).lower()
    i += 1
    while i < hi and (b[i] == SP or b[i] == HT):
        i += 1
    var e = hi
    while e > i and (b[e - 1] == SP or b[e - 1] == HT):
        e -= 1
    for k in range(i, e):
        if (b[k] < 32 and b[k] != HT) or b[k] == 127:
            return 400
    req.names.append(name^)
    req.values.append(_str(b, i, e))
    return 0


def parse_request(buf: Span[UInt8, _], mut req: Request, lim: Limits) -> Parsed:
    """Parse one request from the front of buf into req (cleared first)."""
    req = Request()
    var he = _head_end(buf, lim.max_head)
    if he < 0:
        # No terminator yet: past the cap it can never fit; a bare LF can never become a valid line end.
        if len(buf) >= lim.max_head:
            return Parsed(0, 431)
        for i in range(len(buf)):
            if buf[i] == LF and (i == 0 or buf[i - 1] != CR):
                return Parsed(0, 400)
        var first = _find_crlf(buf, 0, len(buf))
        if first >= 0:  # a bad request line is final, whatever follows
            if first == 0:
                return Parsed(0, 400)
            var st = _request_line(buf, 0, first, req)
            if st != 0:
                return Parsed(0, st)
        return Parsed()
    var le = _find_crlf(buf, 0, he)
    if le == 0:
        return Parsed(0, 400)
    var st = _request_line(buf, 0, le, req)
    if st != 0:
        return Parsed(0, st)
    var at = le + 2
    while at < he - 2:
        le = _find_crlf(buf, at, he)
        if le == at:
            break
        st = _header_line(buf, at, le, req)
        if st != 0:
            return Parsed(0, st)
        at = le + 2
    var q = req.target.find("?")
    req.path = String(req.target[byte = 0:q]) if q >= 0 else req.target
    req.query = String(req.target[byte = q + 1 :]) if q >= 0 else String()
    # Host: exactly one on HTTP/1.1.
    var hosts = 0
    var cls = List[String]()
    var tes = 0
    var te = String()
    for i in range(len(req.names)):
        if req.names[i] == "host":
            hosts += 1
        elif req.names[i] == "content-length":
            for p in req.values[i].split(","):
                cls.append(String(p.strip()))
        elif req.names[i] == "transfer-encoding":
            tes += 1
            te = req.values[i].lower()
    if (req.minor == 1 and hosts == 0) or hosts > 1:
        return Parsed(0, 400)
    var cont = req.header("expect").lower() == "100-continue"
    if len(cls) > 0:  # h11 folds repeated Content-Length into one header holding the number
        var names = List[String]()
        var values = List[String]()
        var seen = False
        for i in range(len(req.names)):
            if req.names[i] != "content-length" or not seen:
                names.append(req.names[i])
                values.append(String(_digits(cls[0])) if req.names[i] == "content-length" else req.values[i])
                seen = seen or req.names[i] == "content-length"
        req.names = names^
        req.values = values^
    for i in range(len(req.names)):
        if req.names[i] == "transfer-encoding":
            req.values[i] = req.values[i].lower()
    if tes > 0:
        if len(cls) > 0:
            return Parsed(0, 400)
        if tes > 1 or te != "chunked" or req.minor == 0:
            return Parsed(0, 501 if req.minor == 1 else 400)
        return _chunked(buf, he, req, lim, cont)
    var n = 0
    if len(cls) > 0:
        n = _digits(cls[0])
        for c in cls:
            if _digits(c) != n:
                return Parsed(0, 400)
        if n < 0:
            return Parsed(0, 400)
    if n > lim.max_body:
        return Parsed(0, 413)
    if len(buf) - he < n:
        return Parsed(0, 0, cont)
    req.body = List[UInt8](buf[he : he + n])
    return Parsed(he + n)


def _chunked(buf: Span[UInt8, _], start: Int, mut req: Request, lim: Limits, cont: Bool) -> Parsed:
    """Decode the chunked body at buf[start:]; used = 0 when it is not all there yet."""
    var at = start
    var n = len(buf)
    while True:
        var le = _find_crlf(buf, at, n)
        if le < 0:
            if n - at > 4096:
                return Parsed(0, 400)
            return Parsed(0, 0, cont)
        var size = 0
        var i = at
        while i < le and _hex(buf[i]) >= 0:
            size = size * 16 + _hex(buf[i])
            if i - at >= 16:
                return Parsed(0, 413)
            i += 1
        if i == at:
            return Parsed(0, 400)
        if i < le and buf[i] != 59 and buf[i] != SP and buf[i] != HT:  # ';' extension or OWS only
            return Parsed(0, 400)
        if len(req.body) + size > lim.max_body:
            return Parsed(0, 413)
        at = le + 2
        if size == 0:
            while True:  # trailer section: header lines, then an empty line
                le = _find_crlf(buf, at, n)
                if le < 0:
                    return Parsed(0, 0, cont) if n - at < lim.max_head else Parsed(0, 431)
                if le == at:
                    return Parsed(le + 2)
                var junk = Request()
                var st = _header_line(buf, at, le, junk)
                if st != 0:
                    return Parsed(0, st)
                at = le + 2
        if n - at < size + 2:
            return Parsed(0, 0, cont)
        if buf[at + size] != CR or buf[at + size + 1] != LF:
            return Parsed(0, 400)
        req.body.extend(buf[at : at + size])
        at += size + 2


def reason(status: Int) -> String:
    if status == 100:
        return "Continue"
    if status == 200:
        return "OK"
    if status == 201:
        return "Created"
    if status == 202:
        return "Accepted"
    if status == 204:
        return "No Content"
    if status == 301:
        return "Moved Permanently"
    if status == 302:
        return "Found"
    if status == 304:
        return "Not Modified"
    if status == 400:
        return "Bad Request"
    if status == 401:
        return "Unauthorized"
    if status == 403:
        return "Forbidden"
    if status == 404:
        return "Not Found"
    if status == 405:
        return "Method Not Allowed"
    if status == 408:
        return "Request Timeout"
    if status == 411:
        return "Length Required"
    if status == 413:
        return "Payload Too Large"
    if status == 414:
        return "URI Too Long"
    if status == 415:
        return "Unsupported Media Type"
    if status == 422:
        return "Unprocessable Entity"
    if status == 429:
        return "Too Many Requests"
    if status == 431:
        return "Request Header Fields Too Large"
    if status == 500:
        return "Internal Server Error"
    if status == 501:
        return "Not Implemented"
    if status == 502:
        return "Bad Gateway"
    if status == 503:
        return "Service Unavailable"
    if status == 504:
        return "Gateway Timeout"
    if status == 505:
        return "HTTP Version Not Supported"
    return "Status"


struct Response(Copyable, Movable):
    var status: Int
    var names: List[String]
    var values: List[String]
    var body: List[UInt8]

    def __init__(out self, status: Int = 200):
        self.status = status
        self.names = List[String]()
        self.values = List[String]()
        self.body = List[UInt8]()

    @staticmethod
    def text(status: Int, body: String, content_type: String = "text/plain; charset=utf-8") -> Response:
        var r = Response(status)
        r.add("content-type", content_type)
        r.body.extend(body.as_bytes())
        return r^

    def add(mut self, name: String, value: String):
        self.names.append(name)
        self.values.append(value)

    def encode(self, minor: Int, keep_alive: Bool, head_only: Bool, mut out: List[UInt8]):
        """Append the wire form. HEAD keeps Content-Length and drops the body; 1xx, 204 and 304 carry neither."""
        out.extend(("HTTP/1." + String(minor) + " " + String(self.status) + " " + reason(self.status) + "\r\n").as_bytes())
        for i in range(len(self.names)):
            out.extend((self.names[i] + ": " + self.values[i] + "\r\n").as_bytes())
        var bodyless = self.status == 204 or self.status == 304 or self.status < 200
        if not bodyless:
            out.extend(("content-length: " + String(len(self.body)) + "\r\n").as_bytes())
        if not keep_alive:
            out.extend("connection: close\r\n".as_bytes())
        elif minor == 0:
            out.extend("connection: keep-alive\r\n".as_bytes())
        out.extend("\r\n".as_bytes())
        if not head_only and not bodyless:
            out.extend(Span(self.body))
