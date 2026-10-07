# Copyright 2026 amarbaro.org. Licensed under the Apache License, Version 2.0.
from .parser import (
    Ast, Node, N_EMPTY, N_LIT, N_CLASS, N_ANY, N_CAT, N_ALT, N_REPEAT, N_LOOK, N_BOL, N_EOL,
)
from .classes import CharClass, CaseMap

comptime I_CHAR = 0
comptime I_CLASS = 1
comptime I_ANY = 2
comptime I_SPLIT = 3
comptime I_JMP = 4
comptime I_MATCH = 5
comptime I_LOOK = 6
comptime I_LOOK_END = 7
comptime I_BOL = 8
comptime I_EOL = 9


@fieldwise_init
struct Inst(Copyable, Movable):
    var op: UInt8
    var ci: Bool
    var neg: Bool
    var a: Int32
    var b: Int32


struct Program(Copyable, Movable):
    var code: List[Inst]
    var classes: List[CharClass]
    var cases: CaseMap

    def __init__(out self, ast: Ast):
        self.code = List[Inst]()
        self.classes = ast.classes.copy()
        self.cases = CaseMap()
        self.emit_node(ast, ast.root)
        self.code.append(Inst(UInt8(I_MATCH), False, False, 0, 0))

    def emit(mut self, op: Int, a: Int = 0, b: Int = 0, ci: Bool = False, neg: Bool = False) -> Int:
        self.code.append(Inst(UInt8(op), ci, neg, Int32(a), Int32(b)))
        return len(self.code) - 1

    def emit_node(mut self, ast: Ast, i: Int):
        var n = ast.nodes[i].copy()
        if n.kind == N_EMPTY:
            return
        if n.kind == N_LIT:
            _ = self.emit(I_CHAR, n.cp, 0, n.ci)
        elif n.kind == N_CLASS:
            _ = self.emit(I_CLASS, n.cls, 0, n.ci)
        elif n.kind == N_ANY:
            _ = self.emit(I_ANY)
        elif n.kind == N_BOL:
            _ = self.emit(I_BOL)
        elif n.kind == N_EOL:
            _ = self.emit(I_EOL)
        elif n.kind == N_CAT:
            for k in n.kids:
                self.emit_node(ast, k)
        elif n.kind == N_ALT:
            var jumps = List[Int]()
            for j in range(len(n.kids)):
                if j < len(n.kids) - 1:
                    var split = self.emit(I_SPLIT)
                    self.code[split].a = Int32(split + 1)
                    self.emit_node(ast, n.kids[j])
                    jumps.append(self.emit(I_JMP))
                    self.code[split].b = Int32(len(self.code))
                else:
                    self.emit_node(ast, n.kids[j])
            for jp in jumps:
                self.code[jp].a = Int32(len(self.code))
        elif n.kind == N_REPEAT:
            for _ in range(n.lo):
                self.emit_node(ast, n.kids[0])
            if n.hi == -1:
                var split = self.emit(I_SPLIT)
                self.code[split].a = Int32(split + 1)
                self.emit_node(ast, n.kids[0])
                _ = self.emit(I_JMP, split)
                self.code[split].b = Int32(len(self.code))
            else:
                var splits = List[Int]()
                for _ in range(n.hi - n.lo):
                    var split = self.emit(I_SPLIT)
                    self.code[split].a = Int32(split + 1)
                    splits.append(split)
                    self.emit_node(ast, n.kids[0])
                for sp in splits:
                    self.code[sp].b = Int32(len(self.code))
        elif n.kind == N_LOOK:
            var look = self.emit(I_LOOK, 0, 0, False, n.neg)
            self.emit_node(ast, n.kids[0])
            _ = self.emit(I_LOOK_END)
            self.code[look].a = Int32(len(self.code))

    def char_eq(self, a: Int, b: Int, ci: Bool) -> Bool:
        if a == b:
            return True
        if not ci:
            return False
        return self.cases.fold(a) == self.cases.fold(b) or self.cases.up(a) == self.cases.up(b)

    def class_has(self, cls: Int, cp: Int, ci: Bool) -> Bool:
        if self.classes[cls].contains(cp):
            return True
        if not ci:
            return False
        return self.classes[cls].contains(self.cases.fold(cp)) or self.classes[cls].contains(self.cases.up(cp))

    def exec(self, text: Span[Byte, _], mut stack: List[Int32], start_pc: Int, start_pos: Int, sub: Bool) -> Int:
        """Backtracking run. `stack` is caller-owned scratch, left as it was found on return."""
        var n = len(text)
        var base = len(stack)
        var pc = start_pc
        var pos = start_pos
        while True:
            ref ins = self.code[pc]
            var op = Int(ins.op)
            var ok = True
            if op == I_MATCH:
                if not sub:
                    stack.shrink(base)
                    return pos
                ok = False
            elif op == I_LOOK_END:
                if sub:
                    stack.shrink(base)
                    return pos
                pc += 1
                continue
            elif op == I_CHAR:
                if pos < n:
                    var d = decode_utf8(text, pos)
                    if self.char_eq(d[0], Int(ins.a), ins.ci):
                        pos += d[1]
                        pc += 1
                    else:
                        ok = False
                else:
                    ok = False
            elif op == I_CLASS:
                if pos < n:
                    var d = decode_utf8(text, pos)
                    if self.class_has(Int(ins.a), d[0], ins.ci):
                        pos += d[1]
                        pc += 1
                    else:
                        ok = False
                else:
                    ok = False
            elif op == I_ANY:
                if pos < n and text[pos] != 10:
                    pos += utf8_len(text[pos])
                    pc += 1
                else:
                    ok = False
            elif op == I_BOL:
                if pos == 0:
                    pc += 1
                else:
                    ok = False
            elif op == I_EOL:
                if pos == n:
                    pc += 1
                else:
                    ok = False
            elif op == I_JMP:
                pc = Int(ins.a)
            elif op == I_SPLIT:
                stack.append(ins.b)
                stack.append(Int32(pos))
                pc = Int(ins.a)
            elif op == I_LOOK:
                var r = self.exec(text, stack, pc + 1, pos, True)
                if (r >= 0) == ins.neg:
                    ok = False
                else:
                    pc = Int(ins.a)
            if not ok:
                if len(stack) == base:
                    return -1
                pos = Int(stack.pop())
                pc = Int(stack.pop())


@always_inline
def utf8_len(b0: Byte) -> Int:
    if b0 < 0x80:
        return 1
    if b0 < 0xE0:
        return 2
    if b0 < 0xF0:
        return 3
    return 4


@always_inline
def decode_utf8(text: Span[Byte, _], pos: Int) -> Tuple[Int, Int]:
    """Codepoint at byte `pos` and its byte length. `text` is valid UTF-8."""
    var b0 = Int(text[pos])
    if b0 < 0x80:
        return (b0, 1)
    if b0 < 0xE0:
        return (((b0 & 0x1F) << 6) | (Int(text[pos + 1]) & 0x3F), 2)
    if b0 < 0xF0:
        return (((b0 & 0x0F) << 12) | ((Int(text[pos + 1]) & 0x3F) << 6) | (Int(text[pos + 2]) & 0x3F), 3)
    return (
        ((b0 & 0x07) << 18) | ((Int(text[pos + 1]) & 0x3F) << 12)
        | ((Int(text[pos + 2]) & 0x3F) << 6) | (Int(text[pos + 3]) & 0x3F),
        4,
    )
