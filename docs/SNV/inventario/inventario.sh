#!/usr/bin/env bash
# Refaz o inventário dos dados do SNV descrito em docs/SNV/README.md.
# Só leitura: não extrai, não converte e não altera nenhum arquivo original.
# Uso (de qualquer pasta): bash docs/SNV/inventario/inventario.sh
# Python: usa "python" do PATH; para outro, PYTHON=/caminho/python bash ...
set -euo pipefail

AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SNV="$(cd "$AQUI/.." && pwd)"
PY="${PYTHON:-python}"

cd "$SNV"

echo "### Hashes (precisam bater com o README; se não baterem, o inventário para)"
sha256sum -c <<'FIM'
d151bc8b9b21451292c414ff02e3f4cd5e178cb49765029e5abc1aa34ca40f46  202610A.zip
28c87a64189ba7a0d8e2960c4f7d4fea1f4997a780c7f93ccc08c371b97fa560  rota_202610A.zip
0af6d9066f2436f1ed8d0cd869ebf196544ccdb66aeb159865bfc56e678d41c4  SNV_202610A.xls
92dabeab1c398b2dbe35a8a9a15ee20922b03949cfae6c1e517059f0efa135c9  GUIA SNV_2025.pdf
FIM

echo
echo "### Tamanhos (bytes)"
wc -c 202610A.zip rota_202610A.zip SNV_202610A.xls "GUIA SNV_2025.pdf"

echo
echo "### Conteúdo dos zips"
unzip -l 202610A.zip
unzip -l rota_202610A.zip

echo
echo "### Shapefile dos trechos"
"$PY" -I "$AQUI/shp_info.py" 202610A.zip

echo "### Shapefile das rotas"
"$PY" -I "$AQUI/shp_info.py" rota_202610A.zip

echo "### Planilha"
"$PY" -I "$AQUI/xls_info.py" SNV_202610A.xls

echo
echo "### Manual (metadados e capa)"
"$PY" -I "$AQUI/pdf_texto.py" "GUIA SNV_2025.pdf" 1

echo
echo "### Conferências cruzadas"
"$PY" -I "$AQUI/conferencias.py" "$SNV"
