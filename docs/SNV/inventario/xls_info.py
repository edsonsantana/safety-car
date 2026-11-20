"""Leitor mínimo de .xls (OLE2 + BIFF8), só biblioteca padrão e só leitura.

Uso: python -I xls_info.py arquivo.xls

Mostra as abas, a dimensão de cada uma, as primeiras linhas e a última.
Lê só o stream "Workbook": não lê as propriedades do documento (autor etc.).
Células de fórmula com resultado em texto aparecem como "<fórmula>".
"""
import struct
import sys

LINHAS_INICIAIS = 8


def ole_stream(data, nome_alvo):
    """Devolve o conteúdo de um stream de um arquivo OLE2 (Compound File)."""
    ssz = 1 << struct.unpack("<H", data[30:32])[0]
    nfat, = struct.unpack("<I", data[44:48])
    dir1, = struct.unpack("<i", data[48:52])
    difat1, = struct.unpack("<i", data[68:72])
    ndifat, = struct.unpack("<I", data[72:76])

    def setor(s):
        return data[512 + s * ssz: 512 + (s + 1) * ssz]

    difat = list(struct.unpack("<109i", data[76:512]))
    s = difat1
    for _ in range(ndifat):
        v = struct.unpack(f"<{ssz // 4}i", setor(s))
        difat += v[:-1]
        s = v[-1]
    fat = []
    for s in difat[:nfat]:
        fat += struct.unpack(f"<{ssz // 4}i", setor(s))

    def cadeia(s):
        out = []
        while s >= 0:
            out.append(setor(s))
            s = fat[s]
        return b"".join(out)

    diretorio = cadeia(dir1)
    for i in range(0, len(diretorio), 128):
        e = diretorio[i:i + 128]
        nl, = struct.unpack("<H", e[64:66])
        if e[:max(nl - 2, 0)].decode("utf-16-le") == nome_alvo:
            inicio, tamanho = struct.unpack("<iI", e[116:124])
            return cadeia(inicio)[:tamanho]
    raise SystemExit(f"stream {nome_alvo} não encontrado")


def registros(wb, pos=0):
    """Gera (posição, tipo, dados) dos registros BIFF a partir de pos."""
    while pos + 4 <= len(wb):
        t, n = struct.unpack("<HH", wb[pos:pos + 4])
        yield pos, t, wb[pos + 4:pos + 4 + n]
        pos += 4 + n


class LeitorContinuo:
    """Lê através de registros CONTINUE; em texto, relê o byte de opção a cada bloco."""

    def __init__(self, blocos):
        self.b, self.i, self.p = blocos, 0, 0

    def bytes(self, n):
        out = b""
        while n:
            if self.p >= len(self.b[self.i]):
                self.i, self.p = self.i + 1, 0
            k = min(n, len(self.b[self.i]) - self.p)
            out += self.b[self.i][self.p:self.p + k]
            self.p += k
            n -= k
        return out

    def caracteres(self, n, largo):
        out = []
        while n:
            if self.p >= len(self.b[self.i]):
                self.i += 1
                largo = self.b[self.i][0] & 1
                self.p = 1
            largura = 2 if largo else 1
            k = min(n, (len(self.b[self.i]) - self.p) // largura)
            seg = self.b[self.i][self.p:self.p + k * largura]
            out.append(seg.decode("utf-16-le") if largo else seg.decode("latin-1"))
            self.p += k * largura
            n -= k
        return "".join(out)


def texto_unicode(leitor):
    n, = struct.unpack("<H", leitor.bytes(2))
    opcao = leitor.bytes(1)[0]
    rich = struct.unpack("<H", leitor.bytes(2))[0] if opcao & 8 else 0
    ext = struct.unpack("<I", leitor.bytes(4))[0] if opcao & 4 else 0
    s = leitor.caracteres(n, opcao & 1)
    leitor.bytes(rich * 4)
    leitor.bytes(ext)
    return s


def rk(v):
    """Decodifica um valor RK do BIFF8."""
    if v & 2:
        x = v >> 2
        if x & (1 << 29):
            x -= 1 << 30
    else:
        x = struct.unpack("<d", struct.pack("<Q", (v & 0xFFFFFFFC) << 32))[0]
    return x / 100 if v & 1 else x


def ler_pasta(caminho):
    """Devolve (abas, celulas_por_aba). abas = [(nome, visibilidade, tipo, dimensão)]."""
    wb = ole_stream(open(caminho, "rb").read(), "Workbook")
    recs = list(registros(wb))
    abas, sst = [], []
    for idx, (_pos, t, d) in enumerate(recs):
        if t == 0x0085:  # BOUNDSHEET
            p, vis, tipo, n, f = struct.unpack("<IBBBB", d[:8])
            nome = d[8:8 + n * 2].decode("utf-16-le") if f & 1 else d[8:8 + n].decode("latin-1")
            abas.append([nome, p, vis, tipo])
        elif t == 0x00FC:  # SST, com os CONTINUE seguintes
            blocos, j = [d[8:]], idx + 1
            while recs[j][1] == 0x003C:
                blocos.append(recs[j][2])
                j += 1
            _total, unicos = struct.unpack("<II", d[:8])
            leitor = LeitorContinuo(blocos)
            sst = [texto_unicode(leitor) for _ in range(unicos)]

    resultado = []
    for nome, p, vis, tipo in abas:
        cel, dim = {}, None
        for _, t, d in registros(wb, p):
            if t == 0x000A:  # EOF
                break
            if t == 0x0200:  # DIMENSION
                dim = struct.unpack("<IIHH", d[:12])
            elif t == 0x00FD:  # LABELSST
                r, c, _, i = struct.unpack("<HHHI", d[:10])
                cel[(r, c)] = sst[i]
            elif t == 0x0203:  # NUMBER
                r, c, _, v = struct.unpack("<HHHd", d[:14])
                cel[(r, c)] = v
            elif t == 0x027E:  # RK
                r, c, _, v = struct.unpack("<HHHI", d[:10])
                cel[(r, c)] = rk(v)
            elif t == 0x00BD:  # MULRK
                r, c0 = struct.unpack("<HH", d[:4])
                for k in range((len(d) - 6) // 6):
                    cel[(r, c0 + k)] = rk(struct.unpack("<I", d[4 + k * 6 + 2:4 + k * 6 + 6])[0])
            elif t == 0x0006:  # FORMULA (valor em cache)
                r, c = struct.unpack("<HH", d[:4])
                res = d[6:14]
                cel[(r, c)] = "<fórmula>" if res[6:8] == b"\xff\xff" else struct.unpack("<d", res)[0]
        resultado.append(((nome, vis, tipo, dim), cel))
    return resultado


VISIBILIDADE = {0: "visível", 1: "oculta", 2: "muito oculta"}
TIPO_ABA = {0: "planilha", 2: "gráfico", 6: "VB"}

if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8")
    pasta = ler_pasta(sys.argv[1])
    print("abas:", [(a[0], VISIBILIDADE.get(a[1], a[1]), TIPO_ABA.get(a[2], a[2])) for a, _ in pasta])
    for (nome, _vis, _tipo, dim), cel in pasta:
        linhas = sorted({r for r, _ in cel})
        cols = sorted({c for _, c in cel})
        print(f"\n== aba {nome!r}: dimensão {dim}; linhas com dado {len(linhas)}; colunas {len(cols)}")
        for r in linhas[:LINHAS_INICIAIS]:
            print("  linha", r, [cel.get((r, c), "") for c in cols])
        if len(linhas) > LINHAS_INICIAIS:
            print("  ... última linha", linhas[-1], [cel.get((linhas[-1], c), "") for c in cols])
