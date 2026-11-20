# Funções compartilhadas pelos scripts de banco. Usar com: source "$(dirname "$0")/_comum.sh"
# Todo psql roda DENTRO do contêiner (nada é instalado no computador).
# O SQL entra por stdin, o que evita conversão de caminhos do Git Bash no Windows.

shopt -s nullglob

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$RAIZ"

# psql_como <papel> <banco> [opções do psql...]
psql_como() {
  local papel="$1" banco="$2"; shift 2
  MSYS_NO_PATHCONV=1 docker compose exec -T db \
    psql -X -q -v ON_ERROR_STOP=1 -v VERBOSITY=terse -U "$papel" -d "$banco" "$@"
}

# le_env <NOME>: imprime o valor de NOME=valor do .env da raiz, sem executar o arquivo
# ("source"), tirando aspas simples ou duplas das pontas. Vazio se a variável não existir.
le_env() {
  local nome="$1" linha
  [[ -f .env ]] || { echo "ERRO: .env não encontrado na raiz do projeto." >&2; exit 1; }
  linha="$(grep -E "^${nome}=" .env | tail -n 1 || true)"
  linha="${linha#*=}"
  linha="${linha%$'\r'}"
  linha="${linha#\"}"; linha="${linha%\"}"
  linha="${linha#\'}"; linha="${linha%\'}"
  printf '%s' "$linha"
}

exige_banco_saudavel() {
  local estado
  estado="$(docker compose ps --format '{{.Health}}' db 2>/dev/null || true)"
  if [[ "$estado" != "healthy" ]]; then
    echo "ERRO: o contêiner 'db' não está saudável (estado: '${estado:-parado}'). Rode: docker compose up -d" >&2
    exit 1
  fi
}
