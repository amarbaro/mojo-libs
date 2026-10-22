"""B8: the mojo-baro engine as a bento service.

    POST /generate         token ids (or text) in, tokens out; requests are batched by a Batcher
    POST /generate_serial  the same, one request at a time under a lock: the unbatched baseline
    POST /v1/chat/completions   OpenAI-shaped, chat template and tokenizer from the model's GGUF (greedy)
    GET  /health

The engine decodes one request at a time, so batching here is admission: a batch of requests reaches the engine
as one burst of lines and the engine never waits for the next one (docs/baro.md).
"""
from std.ffi import external_call
from std.memory import alloc
from json import Json, parse
from minja import render_chat
from tokenizer import Tokenizer
from bento.baro import Engine, Call, run_calls
from bento.baro_wire import GenReq, GenResp
from bento.batch import Batcher
from bento.endpoint import Service, Endpoint, Field, T_STR, T_INT, T_BOOL, T_LIST, http_error
from bento.http import Request, Response
from bento.server import Handler
from bento.sync import Mutex

comptime OVERLOADED = "batcher: overloaded"


struct Ctx(Movable):
    """Shared by every worker thread; heap-allocated so the endpoints can hold its address."""

    var engine: Int  # Engine core address
    var batcher: Int  # Batcher[Call, GenResp] address
    var gate: Mutex  # the unbatched path runs one request at a time under this
    var tok: Int  # Tokenizer address, 0 without a GGUF
    var tok_mu: Mutex
    var tmax: Int
    var model: String
    var served: Int

    def __init__(out self, engine: Int, batcher: Int, tok: Int, tmax: Int, model: String):
        self.engine = engine
        self.batcher = batcher
        self.gate = Mutex()
        self.tok = tok
        self.tok_mu = Mutex()
        self.tmax = tmax
        self.model = model
        self.served = 0


comptime CtxP = MutPointer[Ctx, MutUntrackedOrigin]


def run_gen(ctx: CtxP, var req: GenReq, batched: Bool) raises -> GenResp:
    var r: GenResp
    if batched:
        try:
            r = MutPointer[Batcher[Call, GenResp], MutUntrackedOrigin](unsafe_from_address=ctx[].batcher)[].submit(Call(ctx[].engine, req^))
        except e:
            if String(e).startswith(OVERLOADED):
                raise http_error(503, String(e))
            raise e^
    else:
        ctx[].gate.lock()
        try:
            r = Engine(core=ctx[].engine).generate(req)
        except e:
            ctx[].gate.unlock()
            raise e^
        ctx[].gate.unlock()
    if r.error.byte_length() > 0:
        raise http_error(503 if r.error.startswith("baro: engine exited") else 400, r.error)
    return r^


def _tokens_json(toks: List[Int]) -> Json:
    var a = Json.array()
    for t in toks:
        a.push(Json.of(t))
    return a^


def _encode(ctx: CtxP, text: String, add_special: Bool) raises -> List[Int]:
    if ctx[].tok == 0:
        raise http_error(400, "no tokenizer loaded: pass token ids in `prompt`, or start with --gguf")
    ctx[].tok_mu.lock()
    var out: List[Int]
    try:
        out = MutPointer[Tokenizer, MutUntrackedOrigin](unsafe_from_address=ctx[].tok)[].encode(text, add_special)
    except e:
        ctx[].tok_mu.unlock()
        raise e^
    ctx[].tok_mu.unlock()
    return out^


def _decode(ctx: CtxP, toks: List[Int]) -> String:
    if ctx[].tok == 0:
        return String()
    ctx[].tok_mu.lock()
    var s = MutPointer[Tokenizer, MutUntrackedOrigin](unsafe_from_address=ctx[].tok)[].decode(toks)
    ctx[].tok_mu.unlock()
    return s^


def _generate(ctx: CtxP, args: Json, batched: Bool) raises -> Json:
    var prompt = List[Int]()
    var p = args.get("prompt")
    for i in range(p.len()):
        prompt.append(p.at(i).int())
    var text = args.get("text").str()
    if len(prompt) == 0:
        if text.byte_length() == 0:
            raise http_error(400, "give `prompt` (token ids) or `text`")
        prompt = _encode(ctx, text, True)
    var n = args.get("n").int()
    if n < 1:
        raise http_error(400, "n must be >= 1")
    if len(prompt) + n > ctx[].tmax:
        raise http_error(400, "len(prompt) + n = " + String(len(prompt) + n) + " exceeds the engine's tmax " + String(ctx[].tmax))
    var stop = List[List[Int]]()
    var sj = args.get("stop")
    for i in range(sj.len()):
        stop.append([sj.at(i).int()])
    var r = run_gen(ctx, GenReq(prompt^, n, stop^, 1 if args.get("spec").truthy() else 0), batched)
    var out = Json.object()
    out.set("tokens", _tokens_json(r.tokens))
    out.set("finish", Json.of(r.finish))
    out.set("n", Json.of(len(r.tokens)))
    out.set("prefill_s", Json.of(r.prefill_s))
    out.set("decode_s", Json.of(r.decode_s))
    out.set("tok_s", Json.of(r.tok_s()))
    if ctx[].tok != 0:
        out.set("text", Json.of(_decode(ctx, r.tokens)))
    return out^


def _int_list(name: String) -> Field:
    var f = Field(name, T_LIST, Json.array())  # optional, empty by default
    f.item = T_INT
    return f^


def _generate_fields() -> List[Field]:
    return [
        _int_list("prompt"),
        Field("text", T_STR, Json.of("")),
        Field("n", T_INT, Json.of(64)),
        _int_list("stop"),
        Field("spec", T_BOOL, Json.of(False)),
    ]


struct Generate(Endpoint):
    comptime name = "generate"
    var ctx: Int

    def __init__(out self, ctx: Int):
        self.ctx = ctx

    def fields(self) -> List[Field]:
        return _generate_fields()

    def call(self, args: Json) raises -> Json:
        return _generate(CtxP(unsafe_from_address=self.ctx), args, True)


struct GenerateSerial(Endpoint):
    comptime name = "generate_serial"
    var ctx: Int

    def __init__(out self, ctx: Int):
        self.ctx = ctx

    def fields(self) -> List[Field]:
        return _generate_fields()

    def call(self, args: Json) raises -> Json:
        return _generate(CtxP(unsafe_from_address=self.ctx), args, False)


def _chat_error(status: Int, message: String) -> Response:
    var e = Json.object()
    e.set("message", Json.of(message))
    e.set("type", Json.of("invalid_request_error" if status < 500 else "server_error"))
    var body = Json.object()
    body.set("error", e^)
    return Response.text(status, body.dumps(), "application/json")


def _chat(ctx: CtxP, req: Request, mut resp: Response) raises:
    if req.method != "POST":
        resp = Response.text(405, "Method Not Allowed")
        resp.add("allow", "POST")
        return
    if ctx[].tok == 0:
        resp = _chat_error(400, "chat completions need the model's GGUF (--gguf) for its tokenizer and chat template")
        return
    var body: Json
    try:
        body = parse(Span(req.body))
    except:
        resp = _chat_error(400, "request body is not valid JSON")
        return
    var messages = body.get("messages")
    if messages.len() == 0:
        resp = _chat_error(400, "`messages` must be a non-empty array")
        return
    var max_tokens = body.get("max_tokens").int() if body.has("max_tokens") else 256
    if max_tokens < 1:
        resp = _chat_error(400, "max_tokens must be >= 1")
        return
    var tk = MutPointer[Tokenizer, MutUntrackedOrigin](unsafe_from_address=ctx[].tok)
    var prompt: List[Int]
    ctx[].tok_mu.lock()
    try:
        var text = render_chat(
            tk[].chat_template, '{"messages":' + messages.dumps() + "}", tk[].token_str(tk[].bos_id), tk[].token_str(tk[].eos_id), tk[].token_str(tk[].pad_id)
        )
        prompt = tk[].encode(text, False)
    except e:
        ctx[].tok_mu.unlock()
        resp = _chat_error(400, "cannot render the chat template: " + String(e))
        return
    ctx[].tok_mu.unlock()
    if len(prompt) + max_tokens > ctx[].tmax:
        resp = _chat_error(400, "prompt of " + String(len(prompt)) + " tokens + max_tokens " + String(max_tokens) + " exceeds the engine's tmax " + String(ctx[].tmax))
        return
    var stop = List[List[Int]]()
    stop.append([tk[].eos_id])
    var n_prompt = len(prompt)
    var r: GenResp
    try:
        r = run_gen(ctx, GenReq(prompt^, max_tokens, stop^, 0), True)
    except e:
        var msg = String(e)
        var status = 503 if msg.startswith("HTTP:503") or msg.startswith(OVERLOADED) else 500
        resp = _chat_error(status, msg)
        return
    var toks = r.tokens.copy()
    if len(toks) > 0 and toks[len(toks) - 1] == tk[].eos_id:
        _ = toks.pop()
    var msg = Json.object()
    msg.set("role", Json.of("assistant"))
    msg.set("content", Json.of(_decode(ctx, toks)))
    var choice = Json.object()
    choice.set("index", Json.of(0))
    choice.set("message", msg^)
    choice.set("finish_reason", Json.of("stop" if r.finish == "stop" else "length"))
    var usage = Json.object()
    usage.set("prompt_tokens", Json.of(n_prompt))
    usage.set("completion_tokens", Json.of(len(r.tokens)))
    usage.set("total_tokens", Json.of(n_prompt + len(r.tokens)))
    var choices = Json.array()
    choices.push(choice^)
    var out = Json.object()
    ctx[].served += 1
    out.set("id", Json.of("chatcmpl-" + String(ctx[].served)))
    out.set("object", Json.of("chat.completion"))
    out.set("created", Json.of(Int(external_call["time", Int](Int(0)))))
    out.set("model", Json.of(ctx[].model))
    out.set("choices", choices^)
    out.set("usage", usage^)
    resp = Response.text(200, out.dumps(), "application/json")


struct BaroApp(Handler):
    var ctx: Int
    var service: Service[Generate, GenerateSerial]

    def __init__(out self, ctx: Int):
        self.ctx = ctx
        self.service = Service(Generate(ctx), GenerateSerial(ctx))

    def draining(self):
        self.service.draining()

    def handle(self, req: Request, mut resp: Response) raises:
        var ctx = CtxP(unsafe_from_address=self.ctx)
        if req.path == "/v1/chat/completions":
            _chat(ctx, req, resp)
        elif req.path == "/health":
            var h = Json.object()
            h.set("status", Json.of("ok"))
            h.set("tmax", Json.of(ctx[].tmax))
            h.set("model", Json.of(ctx[].model))
            h.set("tokenizer", Json.of(ctx[].tok != 0))
            resp = Response.text(200, h.dumps(), "application/json")
        else:
            self.service.handle(req, resp)


struct Baro(Movable):
    """The engine, its Batcher and the shared context, started together."""

    var engine: Engine
    var batcher: MutPointer[Batcher[Call, GenResp], MutUntrackedOrigin]
    var ctx: CtxP

    def __init__(
        out self,
        binary: String,
        pack: String,
        run_dir: String,
        gguf: String = "",
        max_batch: Int = 8,
        max_inflight: Int = 1,
        cwd: String = "",
        env: List[String] = [],
    ) raises:
        self.engine = Engine(binary, pack, run_dir, cwd, env)
        self.batcher = alloc[Batcher[Call, GenResp]](1)
        self.batcher.unsafe_write(Batcher[Call, GenResp](run_calls, 3_600_000, max_batch, max_inflight))
        var tok = 0
        if gguf.byte_length() > 0:
            var t = alloc[Tokenizer](1)
            t.unsafe_write(Tokenizer(gguf))
            tok = Int(t)
        self.ctx = alloc[Ctx](1)
        self.ctx.unsafe_write(Ctx(self.engine.address(), Int(self.batcher), tok, self.engine.tmax(), pack))

    def app(self) -> BaroApp:
        return BaroApp(Int(self.ctx))

    def close(self) raises:
        self.batcher[].close()
        self.engine.close()
