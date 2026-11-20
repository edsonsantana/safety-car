"""Inventário de shapefile(s) dentro de um zip, sem extrair nada (só biblioteca padrão).

Uso: python -I shp_info.py arquivo.zip

Mostra, para cada shapefile do zip: arquivos auxiliares, .prj, .cpg, tipo de
geometria, envelope, contagem no .shx e no .dbf, campos, 3 registros de exemplo
e os valores distintos dos campos com poucos valores. Só leitura.
"""
import collections
import struct
import sys
import zipfile

TIPOS = {0: "Null", 1: "Point", 3: "PolyLine", 5: "Polygon", 8: "MultiPoint",
         11: "PointZ", 13: "PolyLineZ", 15: "PolygonZ", 18: "MultiPointZ",
         21: "PointM", 23: "PolyLineM", 25: "PolygonM", 28: "MultiPointM", 31: "MultiPatch"}
OBRIGATORIOS = ("shp", "shx", "dbf", "prj")
LIMITE_DISTINTOS = 30


def ler_dbf(data, encoding):
    """Devolve (n_registros, campos, gerador de (apagado, registro))."""
    nrec, hlen, rlen = struct.unpack("<IHH", data[4:12])
    campos, pos = [], 32
    while data[pos] != 0x0D:
        nome = data[pos:pos + 11].split(b"\0")[0].decode("ascii")
        campos.append((nome, chr(data[pos + 11]), data[pos + 16], data[pos + 17]))
        pos += 32

    def registros():
        for i in range(nrec):
            r = data[hlen + i * rlen: hlen + (i + 1) * rlen]
            out, off = {}, 1
            for nome, _tipo, tam, _dec in campos:
                out[nome] = r[off:off + tam].decode(encoding, "replace").strip()
                off += tam
            yield r[0:1] == b"*", out

    return nrec, campos, registros


def encoding_do_cpg(cpg):
    enc = {"UTF-8": "utf-8", "UTF8": "utf-8"}.get((cpg or "").upper(), cpg or "latin-1")
    try:
        "".encode(enc)
    except LookupError:
        enc = "latin-1"
    return enc


def inventariar(caminho_zip):
    z = zipfile.ZipFile(caminho_zip)
    nomes = z.namelist()
    for base in sorted({n.rsplit(".", 1)[0] for n in nomes if "." in n}):
        exts = sorted(n.rsplit(".", 1)[1].lower() for n in nomes if n.rsplit(".", 1)[0] == base)
        if "shp" not in exts:
            continue
        print(f"== shapefile {base}")
        print("arquivos:", ", ".join("." + e for e in exts))
        falta = [e for e in OBRIGATORIOS if e not in exts]
        print("faltando (.shp, .shx, .dbf, .prj):", ", ".join(falta) or "nenhum")
        prj = z.read(base + ".prj").decode("ascii", "replace") if "prj" in exts else None
        cpg = z.read(base + ".cpg").decode("ascii", "replace").strip() if "cpg" in exts else None
        print("prj:", prj)
        print("cpg:", cpg)

        with z.open(base + ".shp") as f:
            h = f.read(100)
        codigo, = struct.unpack(">i", h[0:4])
        tam_decl, = struct.unpack(">i", h[24:28])
        versao, tipo = struct.unpack("<ii", h[28:36])
        xmin, ymin, xmax, ymax = struct.unpack("<4d", h[36:68])
        zmin, zmax, mmin, mmax = struct.unpack("<4d", h[68:100])
        print(f"shp: código {codigo}, versão {versao}, geometria {tipo} ({TIPOS.get(tipo, '?')})")
        print(f"envelope: x {xmin} a {xmax}; y {ymin} a {ymax}; z {zmin} a {zmax}; m {mmin} a {mmax}")
        real = z.getinfo(base + ".shp").file_size
        print(f"tamanho do .shp: declarado {tam_decl * 2} B, real {real} B, confere: {tam_decl * 2 == real}")

        if "shx" in exts:
            print("registros no .shx:", (len(z.read(base + ".shx")) - 100) // 8)
        if "dbf" not in exts:
            continue
        nrec, campos, registros = ler_dbf(z.read(base + ".dbf"), encoding_do_cpg(cpg))
        print("registros no .dbf:", nrec)
        print("campos (nome, tipo, tamanho, decimais):")
        for c in campos:
            print("  ", c)
        apagados, amostra = 0, []
        distintos = collections.defaultdict(collections.Counter)
        for apagado, r in registros():
            apagados += apagado
            if len(amostra) < 3:
                amostra.append(r)
            for k, v in r.items():
                if len(distintos[k]) <= LIMITE_DISTINTOS:
                    distintos[k][v] += 1
        print("registros apagados no .dbf:", apagados)
        print("3 registros de exemplo:")
        for r in amostra:
            print("  ", r)
        print(f"valores distintos (só campos com até {LIMITE_DISTINTOS}):")
        for k, c in distintos.items():
            if len(c) <= LIMITE_DISTINTOS:
                print(f"  {k}: {len(c)} ->", c.most_common())
            else:
                print(f"  {k}: mais de {LIMITE_DISTINTOS}")
        print()


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8")
    for arquivo in sys.argv[1:]:
        inventariar(arquivo)
