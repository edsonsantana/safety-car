# Funções compartilhadas pelos scripts de banco. Usar com: source "$(dirname "$0")/_comum.sh"
# Todo psql roda DENTRO do contêiner (nada é instalado no computador).
# O SQL entra por stdin, o que evita conversão de caminhos do Git Bash no Windows.

shopt -s nullglob

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$RAIZ"

# Só para testes (ex.: db/scripts/testar_senhas.sh): apontam os scripts para outro contêiner
# e outro arquivo .env. Sem elas, vale o serviço "db" do compose e o .env da raiz.
#   SC_CONTEINER=<nome>      usa "docker exec <nome>" em vez de "docker compose exec db"
#   SC_ENV_ARQUIVO=<caminho> lê as variáveis desse arquivo em vez do .env
ENV_ARQUIVO="${SC_ENV_ARQUIVO:-.env}"

# exec_db [opções do exec, como -e NOME] -- comando...: roda o comando no contêiner do banco,
# com a entrada padrão ligada. "-e NOME" (sem "=valor") repassa a variável do ambiente atual
# sem que o valor apareça na linha de comando.
exec_db() {
  local opcoes=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do opcoes+=("$1"); shift; done
  shift
  if [[ -n "${SC_CONTEINER:-}" ]]; then
    MSYS_NO_PATHCONV=1 docker exec -i "${opcoes[@]}" "$SC_CONTEINER" "$@"
  else
    MSYS_NO_PATHCONV=1 docker compose exec -T "${opcoes[@]}" db "$@"
  fi
}

# psql_como <papel> <banco> [opções do psql...]
psql_como() {
  local papel="$1" banco="$2"; shift 2
  exec_db -- psql -X -q -v ON_ERROR_STOP=1 -v VERBOSITY=terse -U "$papel" -d "$banco" "$@"
}

# le_env <NOME>: imprime o valor de NOME=valor do .env da raiz, sem executar o arquivo
# ("source"), tirando aspas simples ou duplas das pontas. Vazio se a variável não existir.
le_env() {
  local nome="$1" linha
  [[ -f "$ENV_ARQUIVO" ]] || { echo "ERRO: $ENV_ARQUIVO não encontrado." >&2; exit 1; }
  linha="$(grep -E "^${nome}=" "$ENV_ARQUIVO" | tail -n 1 || true)"
  linha="${linha#*=}"
  linha="${linha%$'\r'}"
  linha="${linha#\"}"; linha="${linha%\"}"
  linha="${linha#\'}"; linha="${linha%\'}"
  printf '%s' "$linha"
}

exige_banco_saudavel() {
  local estado
  if [[ -n "${SC_CONTEINER:-}" ]]; then
    if ! exec_db -- pg_isready -q -h 127.0.0.1 -U postgres -d safetycar </dev/null; then
      echo "ERRO: o contêiner '$SC_CONTEINER' não está aceitando conexões." >&2
      exit 1
    fi
    return 0
  fi
  estado="$(docker compose ps --format '{{.Health}}' db 2>/dev/null || true)"
  if [[ "$estado" != "healthy" ]]; then
    echo "ERRO: o contêiner 'db' não está saudável (estado: '${estado:-parado}'). Rode: docker compose up -d" >&2
    exit 1
  fi
}
