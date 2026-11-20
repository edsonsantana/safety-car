"""Metadados e texto aproximado de páginas de um PDF simples (só biblioteca padrão).

Uso: python -I pdf_texto.py arquivo.pdf [página ...]

Sem páginas, mostra só os metadados. Dos metadados, mostra só título, datas e
programa gerador: o autor não é impresso, por poder conter nome de pessoa.
Funciona para PDF sem object streams, com fontes que tenham /ToUnicode; o
texto sai aproximado (quebras e espaços podem vir trocados).
"""
import re
import sys
import zlib

CAMPOS_METADADOS = (b"/Title", b"/CreationDate", b"/ModDate", b"/Producer", b"/Creator")


def objetos(d):
    return {int(m.group(1)): m.group(2) for m in re.finditer(rb"(\d+) 0 obj(.*?)endobj", d, re.S)}


def stream(o):
    m = re.search(rb"stream\r?\n(.*?)endstream", o, re.S)
    if not m:
        return b""
    return zlib.decompress(m.group(1)) if b"/FlateDecode" in o else m.group(1)


def ref(o, chave):
    m = re.search(re.escape(chave) + rb"\s*(\d+) 0 R", o)
    return int(m.group(1)) if m else None


def mapa_unicode(objs, n):
    s, mp = stream(objs[n]), {}
    for blk in re.findall(rb"beginbfchar(.*?)endbfchar", s, re.S):
        for a, b in re.findall(rb"<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>", blk):
            mp[int(a, 16)] = bytes.fromhex(b.decode()).decode("utf-16-be", "replace")
    for blk in re.findall(rb"beginbfrange(.*?)endbfrange", s, re.S):
        for a, b, c in re.findall(rb"<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>", blk):
            for i, k in enumerate(range(int(a, 16), int(b, 16) + 1)):
                mp[k] = chr(int(c, 16) + i)
    return mp


def desescapar(t):
    """Desfaz os escapes de uma string literal de PDF."""
    out, i = bytearray(), 0
    while i < len(t):
        c = t[i]
        if c == 92 and i + 1 < len(t):
            n = t[i + 1]
            if 48 <= n <= 55:
                j, v = i + 1, 0
                while j < len(t) and j < i + 4 and 48 <= t[j] <= 55:
                    v, j = v * 8 + t[j] - 48, j + 1
                out.append(v & 255)
                i = j
                continue
            out.append({110: 10, 114: 13, 116: 9}.get(n, n))
            i += 2
            continue
        out.append(c)
        i += 1
    return bytes(out)


def metadados(d):
    for chave in CAMPOS_METADADOS:
        for m in re.finditer(re.escape(chave) + rb"\s*(\((?:\\.|[^\\)])*\))", d):
            print(chave.decode()[1:] + ":", desescapar(m.group(1)[1:-1]).decode("latin-1"))
    print("páginas:", len(ordem_das_paginas(objetos(d))))


def ordem_das_paginas(objs):
    raiz = next(o for o in objs.values() if re.search(rb"/Type\s*/Pages", o) and b"/Parent" not in o)
    kids = re.search(rb"/Kids\s*\[(.*?)\]", raiz, re.S).group(1)
    return [int(x) for x in re.findall(rb"(\d+) 0 R", kids)]


def texto_da_pagina(objs, ordem, numero):
    po = objs[ordem[numero - 1]]
    r = ref(po, b"/Resources")
    res = objs[r] if r else po
    fm = re.search(rb"/Font\s*(<<.*?>>|\d+ 0 R)", res, re.S).group(1)
    if fm.endswith(b"R"):
        fm = objs[int(fm.split()[0])]
    fontes = {}
    for nome, num in re.findall(rb"/(\w+)\s+(\d+) 0 R", fm):
        tu = ref(objs[int(num)], b"/ToUnicode")
        fontes[nome] = mapa_unicode(objs, tu) if tu else {}
    cs = re.search(rb"/Contents\s*(\[.*?\]|\d+ 0 R)", po, re.S).group(1)
    conteudo = b"".join(stream(objs[int(n)]) for n in re.findall(rb"(\d+) 0 R", cs))
    out, atual = [], {}
    for tok in re.finditer(rb"/(\w+)\s+[\d.]+\s+Tf|\((?:\\.|[^\\)])*\)|<[0-9A-Fa-f]+>|(T\*|Td|TD|ET)", conteudo):
        t = tok.group(0)
        if tok.group(1):
            atual = fontes.get(tok.group(1), {})
        elif tok.group(2):
            out.append(" " if t == b"Td" else "\n")
        else:
            codigos = bytes.fromhex(t[1:-1].decode()) if t[:1] == b"<" else desescapar(t[1:-1])
            out.append("".join(atual.get(c, "?") for c in codigos))
    return re.sub(r"\n\s*\n+", "\n", "".join(out))


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8")
    dados = open(sys.argv[1], "rb").read()
    metadados(dados)
    objs = objetos(dados)
    ordem = ordem_das_paginas(objs)
    for p in map(int, sys.argv[2:]):
        print(f"\n==== página {p}\n{texto_da_pagina(objs, ordem, p)}")
