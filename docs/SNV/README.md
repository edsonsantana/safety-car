# Dados do SNV (Sistema Nacional de Viação)

> **Fonte: SNV/DNIT. A fonte deve ser citada onde o dado for usado.**

Esta pasta guarda os dados públicos do SNV: planilha, shapefile dos trechos, shapefile das rotas e manual. Aqui eles ficam **registrados de forma verificável**: o que é cada arquivo, o hash e o que tem dentro.

Nenhuma decisão de arquitetura foi tomada aqui. O uso de distância rodoviária na cobrança continua pendente, porque depende da licença do SNV e dos termos do provedor (ver `CLAUDE.md` e `docs/BANCO_DE_DADOS.md`, pendência 12).

## Origem

| Campo | Valor |
|---|---|
| Página de origem (URL) | https://www.gov.br/dnit/pt-br/assuntos/atlas-e-mapas/pnv-e-snv |
| Data do download | 21/10/2026 |
| Versão ou data de referência do dado | SNV_202610A |
| Licença ou termos de uso (texto como aparece na página) | citar a fonte - licença livre |

Campos preenchidos pelo Edson em 2026-11-20. O texto da licença está reproduzido exatamente como ele informou.

## Arquivos

| Arquivo | Tipo | Tamanho (bytes) | No Git? | SHA-256 |
|---|---|---|---|---|
| `202610A.zip` | zip com o shapefile dos trechos | 70.435.325 (70,4 MB) | não: acima de ~50 MB | `d151bc8b9b21451292c414ff02e3f4cd5e178cb49765029e5abc1aa34ca40f46` |
| `rota_202610A.zip` | zip com o shapefile das rotas | 90.664.789 (90,7 MB) | não: acima de ~50 MB | `28c87a64189ba7a0d8e2960c4f7d4fea1f4997a780c7f93ccc08c371b97fa560` |
| `SNV_202610A.xls` | planilha Excel 97-2003 (BIFF8) | 2.604.544 (2,6 MB) | não: decisão de manter fora do Git | `0af6d9066f2436f1ed8d0cd869ebf196544ccdb66aeb159865bfc56e678d41c4` |
| `GUIA SNV_2025.pdf` | PDF 1.7, 20 páginas | 2.828.786 (2,8 MB) | não: decisão de manter fora do Git | `92dabeab1c398b2dbe35a8a9a15ee20922b03949cfae6c1e517059f0efa135c9` |

Só este README é versionado. As regras estão no `.gitignore` da raiz.

### Como obter e conferir os arquivos fora do Git

1. Baixe os quatro arquivos da página de origem (campo acima) e coloque-os nesta pasta, com os mesmos nomes.
2. Confira os hashes, no Git Bash, a partir desta pasta:

   ```bash
   sha256sum -c <<'FIM'
   d151bc8b9b21451292c414ff02e3f4cd5e178cb49765029e5abc1aa34ca40f46  202610A.zip
   28c87a64189ba7a0d8e2960c4f7d4fea1f4997a780c7f93ccc08c371b97fa560  rota_202610A.zip
   0af6d9066f2436f1ed8d0cd869ebf196544ccdb66aeb159865bfc56e678d41c4  SNV_202610A.xls
   92dabeab1c398b2dbe35a8a9a15ee20922b03949cfae6c1e517059f0efa135c9  GUIA SNV_2025.pdf
   FIM
   ```

3. Se algum hash não bater, o arquivo é de outra versão. Nesse caso, este inventário precisa ser refeito antes de usar o dado.

## Inventário

O inventário foi feito em 2026-11-20, **só com leitura**. Os shapefiles foram lidos de dentro dos zips, sem extrair nem converter. Como `ogrinfo` e GDAL não estão instalados, a leitura foi feita com os scripts de [`inventario/`](inventario/), em Python, que usam só a biblioteca padrão.

### Como refazer o inventário

Com os quatro arquivos nesta pasta, no Git Bash:

```bash
bash docs/SNV/inventario/inventario.sh            # usa "python" do PATH
PYTHON=/c/Python314/python bash docs/SNV/inventario/inventario.sh   # outro Python
```

O script começa conferindo os hashes e para se algum não bater. Depois mostra os tamanhos, o conteúdo dos zips, os dois shapefiles, a planilha, os metadados e a capa do manual, e as conferências cruzadas das observações.

| Script | O que faz |
|---|---|
| `inventario.sh` | roda tudo, na ordem acima |
| `shp_info.py` | shapefile dentro do zip: arquivos auxiliares, `.prj`, `.cpg`, geometria, envelope, contagens no `.shx` e no `.dbf`, campos, exemplos e valores distintos |
| `xls_info.py` | `.xls` (OLE2 + BIFF8): abas, dimensões e primeiras e última linhas |
| `pdf_texto.py` | título, datas e páginas do PDF e texto aproximado das páginas pedidas |
| `conferencias.py` | códigos da planilha × shapefile, extensão × km, soma das extensões por jurisdição e superfície, trechos com estadual coincidente |

Nenhum script extrai, converte ou altera os originais. Os metadados de autor (da planilha e do PDF) não são impressos.

### Planilha `SNV_202610A.xls`

| Aba | Conteúdo |
|---|---|
| `TABELA SNV` | 2 linhas de cabeçalho ("Versão SNV: 202610A" e um contato institucional), 1 linha de títulos e **7.685 linhas de trecho**, em 20 colunas |
| `RESUMO SNV` | extensão por região e UF, por tipo de superfície (planejada, travessia, leito natural, em obras, implantada, pista simples, pista dupla) |
| `RESUMO ADMINISTRAÇÃO FEDERAL` | o mesmo resumo, só a administração federal |
| `RESUMO ESTADUAL COINCIDENTE` | o mesmo resumo, só as estaduais coincidentes com federal planejada |
| `RESUMO CONCESSÃO FEDERAL` | o mesmo resumo, só as concessões federais |
| `RESUMO CONVÊNIOS DE DELEGAÇÃO` | o mesmo resumo, só os convênios de delegação |

Colunas da `TABELA SNV`: BR, UF, Tipo de trecho, Desc Coinc, Código, Local de Início, Local de Fim, km inicial, km final, Extensão, Superfície Federal, Obras, Federal Coincidente, Administração, Ato legal, Estadual Coincidente, Superfície Est. Coincidente, Jurisdição, Superfície, Unidade Local.

Três linhas de exemplo (sem dado pessoal):

| BR | UF | Tipo | Código | Início | Fim | km ini. | km fim | Extensão | Sup. Federal | Administração | Jurisdição | Superfície |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 010 | DF | Eixo Principal | 010BDF0010 | ENTR BR-010/020/030/450/DF-001 (BRASÍLIA) | ENTR DF-440 | 0,0 | 2,4 | 2,4 | DUP | Convênio Adm.Federal/Estadual | Federal | PAV |
| 010 | DF | Eixo Principal | 010BDF0015 | ENTR DF-440 | ACESSO I SOBRADINHO | 2,4 | 6,0 | 3,6 | DUP | Convênio Adm.Federal/Estadual | Federal | PAV |
| 010 | DF | Eixo Principal | 010BDF0016 | ACESSO I SOBRADINHO | ACESSO II SOBRADINHO | 6,0 | 8,3 | 2,3 | DUP | Convênio Adm.Federal/Estadual | Federal | PAV |

Os 7.685 códigos de trecho da planilha são **exatamente os mesmos** do shapefile dos trechos.

### Shapefile dos trechos (`202610A.zip`)

| Item | Valor |
|---|---|
| Arquivos | `SNV_202610A.shp`, `.shx`, `.dbf`, `.prj` e `.cpg` (UTF-8): **completos**. Também `.sbn` e `.sbx` (índice espacial ESRI, opcional) |
| Geometria | PolyLine (2D) |
| CRS | SIRGAS 2000, geográfico (graus). O `.prj` está em WKT ESRI (`GCS_SIRGAS_2000`), sem código EPSG |
| Extensão | longitude de −73,705 a −32,400; latitude de −33,693 a 4,483 |
| Feições | **7.685**: o `.shx` e o `.dbf` têm a mesma contagem, sem registros apagados. O tamanho do `.shp` confere com o cabeçalho |
| Versão nos dados | `versao_snv = 202610A` e `id_versao = 86` em todos os registros |

Campos (nome, tipo dBase e tamanho):

| Campo | Tipo | Campo | Tipo |
|---|---|---|---|
| `id_trecho_` | N(10) | `ds_coinc` | C(254) |
| `vl_br` | C(3) | `ds_tipo_ad` | C(254) |
| `sg_uf` | C(2) | `ds_ato_leg` | C(254) |
| `nm_tipo_tr` | C(254) | `est_coinc` | C(254) |
| `sg_tipo_tr` | C(1) | `sup_est_co` | C(254) |
| `desc_coinc` | C(254) | `ds_jurisdi` | C(254) |
| `vl_codigo` | C(20) | `ds_superfi` | C(254) |
| `ds_local_i` | C(254) | `ds_legenda` | C(254) |
| `ds_local_f` | C(254) | `sg_legenda` | C(254) |
| `vl_km_inic` | N(19,8) | `leg_multim` | C(254) |
| `vl_km_fina` | N(19,8) | `versao_snv` | C(15) |
| `vl_extensa` | N(19,8) | `id_versao` | N(10) |
| `ds_sup_fed` | C(254) | `marcador` | C(254) |
| `ds_obra` | C(3) | | |
| `ul` | C(254) | | |

Contagens por campo:
- `sg_uf`: 27 UFs.
- `ds_jurisdi`: Federal 6.084, Estadual 1.468, Municipal 94, Distrital 39.
- `ds_sup_fed`: PAV 3.817, PLA 2.322, DUP 1.191, IMP 269, LEN 59, TRV 27.
- `nm_tipo_tr`: Eixo Principal 7.095, Contorno 214, Acesso 191, Travessia Urbana 75, Anel 60, Variante 50.
- `desc_coinc`: "-" 6.839, "Coinc" 846.

### Shapefile das rotas (`rota_202610A.zip`)

| Item | Valor |
|---|---|
| Arquivos | `r202610A.shp`, `.shx`, `.dbf`, `.prj` e `.cpg` (UTF-8): **completos**. Também `.qmd` (metadados do QGIS 3.40) |
| Geometria | **PolyLineM** (linha com medida M); M de 0 a 2000 |
| CRS | SIRGAS 2000, geográfico. O `.prj` é igual ao dos trechos; o `.qmd` identifica como **EPSG:4674** |
| Extensão | a mesma dos trechos |
| Feições | **736**: o `.shx` e o `.dbf` têm a mesma contagem, sem registros apagados |

Campos: `id_rota` N(10), `vl_codigo_` C(15) (ex.: `010BDF202610A`), `id_versao_` N(10) (86 em todas), `id_versa_1` N(10) (nulo em todas), `vl_km_inic` N(24,15) (0 em todas), `vl_km_fina` N(24,15) (ex.: 45,0; 306,3; 378,7).

### Manual `GUIA SNV_2025.pdf`

| Item | Valor |
|---|---|
| Título (capa) | "GUIA SNV – Sistema Nacional de Viação" |
| Realização (capa) | Coordenação-Geral de Planejamento e Programação de Investimentos, "CGPLAN/2025" |
| Versão | **não consta** no texto |
| Data | não consta no texto; os metadados do PDF registram criação em 2026-06-16 |
| Páginas | 20 |
| Conteúdo | objetivo, conceitos, tipos de trecho, coincidência de rodovias, superfície federal, superfície das estaduais coincidentes, obras, administração e jurisdição |

## Observações

Registradas para a decisão futura sobre distância rodoviária. **Nenhuma delas é decisão.**

1. **CRS diferente do banco.** Os dados estão em SIRGAS 2000 (EPSG:4674), e o banco do Safety Car usa `geography(Point, 4326)` (WGS 84). Usá-los exige decidir como tratar essa diferença.
2. **Há quilometragem por trecho.** A planilha e o shapefile trazem km inicial, km final e extensão. A extensão é igual a km final − km inicial nos 7.685 trechos.
3. **Só rodovias federais.** Todo registro tem número de BR.
   - As rodovias estaduais aparecem só onde coincidem com uma BR. Os 1.468 trechos de jurisdição estadual têm Superfície Federal "PLA". Pelo manual (seção 3.4), a condição física da estadual coincidente está em "Superfície Est. Coincidente" (`sup_est_co`).
   - **Rodovias estaduais próprias, municipais e vias urbanas não estão na base.**
4. **Trechos planejados.** 2.322 trechos têm Superfície Federal "PLA". O manual (seção 3.3.1) os descreve como segmentos que "embora constem no SNV, são fisicamente inexistentes sob a esfera federal". Outros 269 trechos são IMP (implantada) e 59 são LEN (leito natural).
5. **Coincidências não se somam.** 846 registros são "Coinc", ou seja, sobreposições de rodovias no mesmo traçado.
   - A soma direta das extensões no shapefile dá 131.670,1 km. O total da aba `RESUMO SNV` é 122.445,8 km.
   - O manual (seção 3.2) diz que o marcador serve a relatórios e é dispensável na análise geoespacial, em que a linha única representa a via física.
6. **Rotas com medida M** de 0 a 2000, e `vl_km_inic` é 0 em todas. Parece ser a quilometragem ao longo da rota (referência linear). **Interpretação a confirmar** no manual ou com a fonte.
7. **Tipos de dado na planilha.** Os km estão como texto com vírgula decimal (`2,4`), e a coluna BR mistura texto (`010`) e número (`499`). O shapefile tem os km como número.
8. **Endereços citados no manual**, mas não conferidos como origem destes arquivos:
   - página do PNV/SNV do DNIT: `https://www.gov.br/dnit/pt-br/assuntos/atlas-e-mapas/pnv-e-snv` (página 4);
   - visualizador VGeo: `https://servicos.dnit.gov.br/vgeo/` (página 13).

   O manual também diz que cada versão do SNV "é identificada pelo ano e mês de publicação, acrescidos de uma letra indicativa, caso ocorra mais de uma atualização no mesmo período" (página 4).
9. **Metadados da planilha.** O campo de autor traz o nome de uma pessoa. Ele não é reproduzido aqui.
