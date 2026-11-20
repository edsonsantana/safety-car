"""Conferências cruzadas do SNV, citadas nas observações do README (só leitura).

Uso: python -I conferencias.py PASTA_DO_SNV   (a pasta com os zips e o .xls)

1. Os códigos de trecho da planilha são os mesmos do shapefile?
2. A extensão é igual a km final - km inicial em todos os trechos?
3. A soma das extensões por jurisdição e superfície federal e o total geral.
4. Quantos trechos têm rodovia estadual coincidente.
"""
import collections
import importlib.util
import os
import sys
import zipfile

sys.dont_write_bytecode = True  # não deixa __pycache__ ao carregar os scripts irmãos
AQUI = os.path.dirname(os.path.abspath(__file__))
TOLERANCIA_KM = 0.05


def carregar(nome):
    """Carrega um script irmão pelo caminho (python -I não põe a pasta no sys.path)."""
    spec = importlib.util.spec_from_file_location(nome, os.path.join(AQUI, nome + ".py"))
    modulo = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(modulo)
    return modulo


def main(pasta):
    xls_info, shp_info = carregar("xls_info"), carregar("shp_info")

    # Planilha: aba TABELA SNV, coluna "Código" (índice 4), a partir da linha 3.
    (_meta, cel), *_ = xls_info.ler_pasta(os.path.join(pasta, "SNV_202610A.xls"))
    codigos_xls = {v for (r, c), v in cel.items() if c == 4 and r >= 3}

    z = zipfile.ZipFile(os.path.join(pasta, "202610A.zip"))
    cpg = z.read("SNV_202610A.cpg").decode("ascii").strip()
    _n, _campos, registros = shp_info.ler_dbf(z.read("SNV_202610A.dbf"), shp_info.encoding_do_cpg(cpg))

    codigos_shp, divergentes, sem_km, com_estadual = set(), 0, 0, 0
    soma = collections.defaultdict(float)
    for _apagado, r in registros():
        codigos_shp.add(r["vl_codigo"])
        if r["est_coinc"]:
            com_estadual += 1
        try:
            ini, fim, ext = float(r["vl_km_inic"]), float(r["vl_km_fina"]), float(r["vl_extensa"])
        except ValueError:
            sem_km += 1
            continue
        if abs((fim - ini) - ext) > TOLERANCIA_KM:
            divergentes += 1
        soma[(r["ds_jurisdi"], r["ds_sup_fed"])] += ext

    print("1. códigos de trecho")
    print(f"   planilha {len(codigos_xls)}, shapefile {len(codigos_shp)}, iguais: {codigos_xls == codigos_shp}")
    print(f"   só na planilha {len(codigos_xls - codigos_shp)}, só no shapefile {len(codigos_shp - codigos_xls)}")
    print("2. extensão = km final - km inicial")
    print(f"   divergentes (> {TOLERANCIA_KM} km): {divergentes}; sem km: {sem_km}")
    print("3. soma das extensões (km) por jurisdição e superfície federal")
    for (jur, sup), km in sorted(soma.items()):
        print(f"   {jur:<10} {sup:<4} {km:>10.1f}")
    print(f"   total (sem tratar coincidências): {sum(soma.values()):.1f}")
    print("4. trechos com rodovia estadual coincidente (est_coinc preenchido):", com_estadual)


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8")
    main(sys.argv[1])
