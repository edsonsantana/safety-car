#!/usr/bin/env bash
# Testes dos modos --verificar e --sincronizar do db/scripts/criar_papeis.sh, fora da suíte padrão.
#
#   bash db/scripts/testar_senhas.sh
#
# - Os papéis valem para o servidor inteiro, então um banco descartável não isola o teste.
#   Por isso ele sobe um CONTÊINER próprio (mesma imagem do compose, sem porta publicada, dados
#   em memória), criado pelo próprio db/init com senhas fictícias, e o remove no fim, mesmo em
#   caso de falha ou Ctrl+C. O contêiner "db" do compose, o volume safetycar_pgdata e o .env
#   não são tocados.
# - O servidor de teste sobe com log_statement=all: se o script não desligasse o registro de
#   comandos na sessão do ALTER ROLE, a senha apareceria no docker logs. O teste confere que não
#   aparece, nem lá nem na saída do script (só imprime a contagem).
# - Cada verificação imprime OK ou FALHOU; o script sai com código 1 se alguma falhar.
set -euo pipefail
source "$(dirname "$0")/_comum.sh"

IMAGEM=postgis/postgis:16-3.6
C=safetycar_teste_senhas
SCRIPT=db/scripts/criar_papeis.sh

if [[ -n "$(docker ps -aq --filter "name=^${C}$")" ]]; then
  echo "ERRO: já existe um contêiner $C (teste anterior interrompido?). Remova com: docker rm -f $C" >&2
  exit 1
fi

TMP="$(mktemp -d)"
limpar() {
  local status=$?
  trap - EXIT
  if docker rm -f "$C" >/dev/null 2>&1; then
    echo "== contêiner $C removido"
  else
    echo "!! não foi possível remover $C; remova à mão: docker rm -f $C" >&2
    status=1
  fi
  rm -rf "$TMP"
  exit "$status"
}
trap limpar EXIT
trap 'exit 130' INT TERM

# Senhas fictícias. As novas têm aspa simples, aspa dupla, $ e barra para testar o escape.
ANT_MIG='antiga-ficticia-migrator-0001'
ANT_APP='antiga-ficticia-app-000000001'
ANT_CEN='antiga-ficticia-central-00001'
NOVA_MIG='Nova$Fict"icia-migrator-2026'
NOVA_APP="Nova'Ficticia\\app-2026-teste"
NOVA_CEN='Nova-Ficticia-central-;2026--x'
OUTRA_APP='Outra-Ficticia-app-2026-zzzzz'
TODAS=("$ANT_MIG" "$ANT_APP" "$ANT_CEN" "$NOVA_MIG" "$NOVA_APP" "$NOVA_CEN" "$OUTRA_APP")
GRAVADAS=("$NOVA_MIG" "$NOVA_APP" "$NOVA_CEN" "$OUTRA_APP")

# escreve_env <migrator> <app> <central> <api_db_senha> [api_db_usuario]
escreve_env() {
  {
    printf 'POSTGRES_PASSWORD=%s\n' 'superusuario-ficticio-teste-01'
    printf 'SAFETYCAR_MIGRATOR_PASSWORD=%s\n' "$1"
    printf 'SAFETYCAR_APP_PASSWORD=%s\n' "$2"
    printf 'SAFETYCAR_CENTRAL_PASSWORD=%s\n' "$3"
    printf 'API_DB_SENHA=%s\n' "$4"
    printf 'API_DB_USUARIO=%s\n' "${5:-safetycar_app}"
    printf 'DB_PORTA=5433\nAPI_DB_PORTA=5433\n'
  } >"$TMP/env"
}

export SC_CONTEINER="$C" SC_ENV_ARQUIVO="$TMP/env"

FALHAS=0; TOTAL=0
ok()     { TOTAL=$((TOTAL + 1)); echo "   OK: $*"; }
falhou() { TOTAL=$((TOTAL + 1)); FALHAS=$((FALHAS + 1)); echo "   FALHOU: $*"; }

# roda <entrada> <argumentos...>: roda o criar_papeis.sh; saída em $TMP/saida (acumulada em
# $TMP/todas_saidas) e código em $STATUS.
roda() {
  local entrada="$1"; shift
  set +e
  printf '%s\n' "$entrada" | bash "$SCRIPT" "$@" >"$TMP/saida" 2>&1
  STATUS=$?
  set -e
  cat "$TMP/saida" >>"$TMP/todas_saidas"
}
contem()     { grep -qF -- "$1" "$TMP/saida"; }
espera()     { if [[ "$STATUS" == "$1" ]]; then ok "$2 (código $1)"; else falhou "$2 (esperado código $1, veio $STATUS)"; sed 's/^/      | /' "$TMP/saida"; fi; }
espera_txt() { if contem "$1"; then ok "$2"; else falhou "$2 (faltou: $1)"; sed 's/^/      | /' "$TMP/saida"; fi; }
nao_txt()    { if contem "$1"; then falhou "$2 (apareceu: $1)"; else ok "$2"; fi; }

# estado <esperado_migrator> <esperado_app> <esperado_central>: confere o --verificar.
estado() {
  roda "" --verificar
  local p e i=0 esperados=("$1" "$2" "$3")
  for p in safetycar_migrator safetycar_app safetycar_central; do
    e="${esperados[$i]}"; i=$((i + 1))
    if contem "$p: $e"; then ok "$4: $p $e"; else falhou "$4: $p deveria estar $e"; sed 's/^/      | /' "$TMP/saida"; fi
  done
}

# ---------------------------------------------------------------------------------------------
echo "== subindo $C ($IMAGEM, sem porta publicada, dados em memória)"
INIT="$(cd db/init && (pwd -W 2>/dev/null || pwd))"
export POSTGRES_PASSWORD='superusuario-ficticio-teste-01'
export SAFETYCAR_MIGRATOR_PASSWORD="$ANT_MIG" SAFETYCAR_APP_PASSWORD="$ANT_APP" SAFETYCAR_CENTRAL_PASSWORD="$ANT_CEN"
MSYS_NO_PATHCONV=1 docker run -d --name "$C" \
  -e POSTGRES_PASSWORD -e SAFETYCAR_MIGRATOR_PASSWORD -e SAFETYCAR_APP_PASSWORD -e SAFETYCAR_CENTRAL_PASSWORD \
  -e TZ=UTC --tmpfs /var/lib/postgresql/data \
  -v "$INIT:/docker-entrypoint-initdb.d:ro" \
  "$IMAGEM" postgres -c log_statement=all >/dev/null
unset POSTGRES_PASSWORD SAFETYCAR_MIGRATOR_PASSWORD SAFETYCAR_APP_PASSWORD SAFETYCAR_CENTRAL_PASSWORD

# Só por TCP: o servidor temporário do init não escuta TCP, então isto espera o servidor final.
for _ in $(seq 1 60); do
  if exec_db -- pg_isready -q -h 127.0.0.1 -U postgres -d safetycar </dev/null 2>/dev/null; then break; fi
  sleep 1
done
exec_db -- pg_isready -q -h 127.0.0.1 -U postgres -d safetycar </dev/null
# Sem as migrações, só o dono conecta; a 0007 e a 0014 dão CONNECT ao app e à Central.
psql_como postgres postgres -c "GRANT CONNECT ON DATABASE safetycar TO safetycar_app, safetycar_central" </dev/null >/dev/null

echo "== pré-condições"
escreve_env "$ANT_MIG" "$ANT_APP" "$ANT_CEN" "$ANT_APP"
estado ok ok ok "senhas do init conferem"
espera 0 "--verificar com tudo certo"

escreve_env "$NOVA_MIG" "$NOVA_APP" "$NOVA_CEN" "$NOVA_APP"
estado FALHOU FALHOU FALHOU "senha errada é recusada (TCP exige senha)"
espera 1 "--verificar com senhas divergentes"
espera_txt "não confere" "motivo: a senha não confere"

echo "== confirmação errada não altera nada"
roda "outro-banco" --sincronizar
espera 1 "--sincronizar com confirmação errada"
espera_txt "Nada foi alterado" "mensagem de nada alterado"
estado FALHOU FALHOU FALHOU "depois da confirmação errada"

echo "== sincroniza os três"
roda "safetycar" --sincronizar
espera 0 "--sincronizar com confirmação certa"
for p in safetycar_migrator safetycar_app safetycar_central; do
  espera_txt "$p: senha alterada." "$p alterado"
done
estado ok ok ok "depois de sincronizar"

echo "== segunda rodada não altera nada (nem pede confirmação)"
roda "" --sincronizar
espera 0 "--sincronizar sem divergência"
espera_txt "Nada foi alterado" "nada alterado"
nao_txt "senha alterada" "nenhum ALTER ROLE"

echo "== só o app diverge: só ele é alterado"
escreve_env "$NOVA_MIG" "$OUTRA_APP" "$NOVA_CEN" "$OUTRA_APP"
roda "safetycar" --sincronizar
espera 0 "--sincronizar só do app"
espera_txt "safetycar_app: senha alterada." "app alterado"
nao_txt "safetycar_migrator: senha alterada." "migrator mantido"
nao_txt "safetycar_central: senha alterada." "central mantido"
estado ok ok ok "depois de sincronizar só o app"

echo "== recusas (nada é alterado)"
escreve_env "$NOVA_MIG" "$NOVA_APP" "$NOVA_CEN" "$OUTRA_APP"
roda "safetycar" --sincronizar
espera 1 "API_DB_SENHA diferente de SAFETYCAR_APP_PASSWORD"
espera_txt "API_DB_SENHA é diferente" "mensagem da API_DB_SENHA"

escreve_env "$NOVA_MIG" "$NOVA_APP" "$NOVA_CEN" "$NOVA_APP" safetycar_migrator
roda "safetycar" --sincronizar
espera 1 "API_DB_USUARIO diferente de safetycar_app"

escreve_env "trocar-senha-migrator" "$NOVA_APP" "$NOVA_CEN" "$NOVA_APP"
roda "safetycar" --sincronizar
espera 1 "valor de exemplo trocar-*"
espera_txt "valor de exemplo" "mensagem do valor de exemplo"

escreve_env "$NOVA_MIG" "curta-demais" "$NOVA_CEN" "curta-demais"
roda "safetycar" --sincronizar
espera 1 "senha com menos de 16 caracteres"
espera_txt "16 caracteres" "mensagem do tamanho"

escreve_env "$NOVA_MIG" "$NOVA_APP" "" "$NOVA_APP"
roda "safetycar" --sincronizar
espera 1 "variável vazia"
espera_txt "defina SAFETYCAR_CENTRAL_PASSWORD" "mensagem da variável vazia"

escreve_env "$NOVA_MIG" "$OUTRA_APP" "$NOVA_CEN" "$OUTRA_APP"
estado ok ok ok "as recusas não alteraram nada"

echo "== modo padrão continua sem trocar senha"
escreve_env "$NOVA_MIG" "$OUTRA_APP" "$ANT_CEN" "$OUTRA_APP"
roda ""
espera 0 "sem argumento"
espera_txt "senha mantida" "papel existente mantém a senha"
escreve_env "$NOVA_MIG" "$OUTRA_APP" "$NOVA_CEN" "$OUTRA_APP"
estado ok ok ok "central manteve a senha sincronizada"

echo "== sigilo"
roda "" --ajuda-inexistente
espera 2 "argumento desconhecido"
docker logs "$C" >"$TMP/logs" 2>&1
if grep -qF "log_statement" "$TMP/logs" || grep -qF "statement:" "$TMP/logs"; then
  ok "o servidor de teste registra comandos (o teste do log é significativo)"
else
  falhou "o servidor de teste não registrou comandos; o teste do log não prova nada"
fi
VAZ_SAIDA=0; VAZ_LOG=0
for s in "${TODAS[@]}"; do
  if grep -qF -- "$s" "$TMP/todas_saidas"; then VAZ_SAIDA=$((VAZ_SAIDA + 1)); fi
done
# No log, só as senhas gravadas pelo criar_papeis.sh: as "antigas" foram criadas pelo
# db/init/01_papeis.sh, que neste servidor de teste também roda com log_statement=all.
for s in "${GRAVADAS[@]}"; do
  if grep -qF -- "$s" "$TMP/logs"; then VAZ_LOG=$((VAZ_LOG + 1)); fi
done
# Controle: o init (sem o SET que desliga o registro) deixou a senha no log, então a busca
# acima acharia uma senha registrada.
if grep -qF -- "$ANT_APP" "$TMP/logs"; then
  ok "controle: senha registrada sem o SET aparece no log"
else
  falhou "controle: a busca no log não achou nem a senha do init"
fi
if (( VAZ_SAIDA == 0 )); then ok "nenhuma senha na saída do script"; else falhou "$VAZ_SAIDA senha(s) na saída do script"; fi
if (( VAZ_LOG == 0 )); then ok "nenhuma senha no log do servidor"; else falhou "$VAZ_LOG senha(s) no log do servidor"; fi

echo
echo "== $((TOTAL - FALHAS))/$TOTAL verificações OK"
(( FALHAS == 0 ))
