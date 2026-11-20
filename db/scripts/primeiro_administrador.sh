#!/usr/bin/env bash
# Define o PRIMEIRO administrador de permissões da Central num ambiente (migração 0014).
#
#   bash db/scripts/primeiro_administrador.sh --email <e-mail> --sub <keycloak_sub> \
#        [--banco safetycar] [--motivo "<texto>"] [--simular]
#
# - Numa única transação, como safetycar_migrator: cria o usuário (perfil central, status ativo)
#   se ainda não existir, grava a auditoria dessa criação e chama conceder_permissao_inicial,
#   que cadastra o operador e concede conceder_permissao com origem "inicial".
# - Reaproveita um usuário já existente só se ele tiver o mesmo keycloak_sub, perfil central, o
#   mesmo e-mail e status ativo. Qualquer divergência aborta sem alterar nada.
# - Se já houver detentor vigente de conceder_permissao, a função recusa (SC018): o script
#   explica e mostra o caminho de recuperação da 0014, mas NÃO o executa.
# - --simular: faz tudo e termina com ROLLBACK (nada é gravado, nem auditoria).
# - Sem --simular, mostra banco, e-mail e keycloak_sub e só grava se você digitar o NOME DO
#   BANCO alvo. Qualquer outra resposta, inclusive vazia, encerra sem gravar.
# - Cada ambiente (ex.: trabalho e casa) tem o seu Keycloak, com usuário e keycloak_sub
#   próprios: o script roda uma vez em cada, com o sub daquele Keycloak.
# - Não lê senha nenhuma: o migrator entra pelo socket local do contêiner.
#
# Saída: 0 = gravado (ou simulação concluída); 1 = erro ou recusa; 2 = confirmação não conferiu.
set -euo pipefail
source "$(dirname "$0")/_comum.sh"

MOTIVO_PADRAO="Primeiro administrador de permissões (db/scripts/primeiro_administrador.sh)"

uso() {
  cat <<'TXT'
Uso: bash db/scripts/primeiro_administrador.sh --email <e-mail> --sub <keycloak_sub>
                                                [--banco safetycar] [--motivo "<texto>"] [--simular]
  --email    e-mail do usuário (o mesmo do Keycloak deste ambiente)
  --sub      ID do usuário no Keycloak deste ambiente (uuid; vira usuario.keycloak_sub)
  --banco    banco alvo (padrão: safetycar; recusa postgres, template0 e template1)
  --motivo   motivo gravado na concessão e na auditoria (padrão: texto fixo do script)
  --simular  mostra o que faria e desfaz tudo (ROLLBACK)
Exemplo (valores fictícios):
  bash db/scripts/primeiro_administrador.sh --email admin@exemplo.invalid \
       --sub 00000000-0000-4000-8000-0000000000a1 --simular
TXT
}

erro() { echo "ERRO: $*" >&2; exit 1; }

EMAIL=""; SUB=""; BANCO="safetycar"; MOTIVO="$MOTIVO_PADRAO"; SIMULAR=0
while (( $# > 0 )); do
  case "$1" in
    --email)   (( $# >= 2 )) || erro "--email precisa de um valor"; EMAIL="$2"; shift 2 ;;
    --sub)     (( $# >= 2 )) || erro "--sub precisa de um valor"; SUB="$2"; shift 2 ;;
    --banco)   (( $# >= 2 )) || erro "--banco precisa de um valor"; BANCO="$2"; shift 2 ;;
    --motivo)  (( $# >= 2 )) || erro "--motivo precisa de um valor"; MOTIVO="$2"; shift 2 ;;
    --simular) SIMULAR=1; shift ;;
    -h|--help) uso; exit 0 ;;
    *) uso >&2; erro "argumento desconhecido: $1" ;;
  esac
done

# ---------------------------------------------------------------------------------------------
# 1. Validação dos argumentos (antes de qualquer conexão)
[[ -n "$EMAIL" ]] || { uso >&2; erro "informe --email"; }
[[ -n "$SUB" ]]   || { uso >&2; erro "informe --sub"; }
[[ "$EMAIL" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] \
  || erro "e-mail com formato inválido: '$EMAIL'"
SUB="${SUB,,}"
[[ "$SUB" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] \
  || erro "keycloak_sub com formato inválido (esperado uuid 8-4-4-4-12): '$SUB'"
[[ "$BANCO" =~ ^[a-z_][a-z0-9_]*$ ]] || erro "nome de banco inválido: '$BANCO'"
case "$BANCO" in
  postgres|template0|template1) erro "o banco '$BANCO' não é um banco da aplicação; recusado" ;;
esac
MOTIVO_SEM_ESPACO="${MOTIVO//[[:space:]]/}"
[[ -n "$MOTIVO_SEM_ESPACO" ]] || erro "o motivo não pode ser vazio"

# ---------------------------------------------------------------------------------------------
# 2. Ambiente: contêiner saudável, banco existente, 0014 aplicada.
# Todo psql recebe o SQL por heredoc: assim nenhum deles consome a entrada padrão, que fica
# reservada para a confirmação. Os valores entram como variáveis do psql (:'nome'), nunca
# colados no texto do SQL.
exige_banco_saudavel </dev/null

existe="$(psql_como postgres postgres -tA -v banco="$BANCO" <<'SQL'
SELECT count(*) FROM pg_database WHERE datname = :'banco';
SQL
)"
[[ "$existe" == 1 ]] || erro "o banco '$BANCO' não existe"

tem_tabela="$(psql_como safetycar_migrator "$BANCO" -tA <<'SQL'
SELECT to_regclass('public.schema_migracao') IS NOT NULL;
SQL
)"
[[ "$tem_tabela" == t ]] \
  || erro "o banco '$BANCO' não tem schema_migracao: as migrações não foram aplicadas (rode: bash db/scripts/migrar.sh $BANCO)"
tem_0014="$(psql_como safetycar_migrator "$BANCO" -tA <<'SQL'
SELECT EXISTS (SELECT 1 FROM schema_migracao WHERE versao = '0014');
SQL
)"
[[ "$tem_0014" == t ]] \
  || erro "o banco '$BANCO' não tem a migração 0014 (operadores e permissões); rode: bash db/scripts/migrar.sh $BANCO"

# ---------------------------------------------------------------------------------------------
# 3. Checagens prévias (só leitura)
mapfile -t PREVIA < <(psql_como safetycar_migrator "$BANCO" -tA -v email="$EMAIL" -v sub="$SUB" <<'SQL'
SELECT coalesce((SELECT perfil || '|' || status || '|' || (email = :'email')::text
                   FROM usuario WHERE keycloak_sub = :'sub'::uuid), '');
SELECT EXISTS (SELECT 1 FROM usuario WHERE email = :'email' AND keycloak_sub <> :'sub'::uuid);
SELECT coalesce((SELECT string_agg(operador_id::text || '|' || to_char(concedida_em, 'YYYY-MM-DD HH24:MI:SS TZ'), ';')
                   FROM vw_permissao_vigente WHERE permissao_codigo = 'conceder_permissao'), '');
SQL
)
(( ${#PREVIA[@]} == 3 )) || erro "falha nas checagens prévias no banco '$BANCO'; nada foi gravado"
EXISTENTE="${PREVIA[0]}"; EMAIL_OUTRO_SUB="${PREVIA[1]}"; DETENTORES="${PREVIA[2]}"

REAPROVEITA=0
if [[ -n "$EXISTENTE" ]]; then
  IFS='|' read -r perfil_atual status_atual email_igual <<<"$EXISTENTE"
  [[ "$perfil_atual" == central ]] \
    || erro "já existe um usuário com esse keycloak_sub e perfil '$perfil_atual'. O perfil não muda (SC001): nada foi gravado."
  [[ "$email_igual" == true ]] \
    || erro "já existe um usuário central com esse keycloak_sub, mas com OUTRO e-mail. Confira o e-mail e o sub do Keycloak deste ambiente: nada foi gravado."
  [[ "$status_atual" == ativo ]] \
    || erro "já existe esse usuário central, mas com status '$status_atual' (precisa ser 'ativo' para a permissão valer): nada foi gravado."
  REAPROVEITA=1
fi
[[ "$EMAIL_OUTRO_SUB" == t ]] \
  && erro "o e-mail '$EMAIL' já pertence a outro usuário, com outro keycloak_sub (provavelmente o de outro ambiente ou de outro Keycloak). Use o sub do Keycloak deste ambiente: nada foi gravado."

explica_sc018() {
  local detentores="$1" primeiro=""
  echo
  echo "RECUSADO (SC018): já existe concessão vigente de conceder_permissao, então a concessão inicial não se aplica." >&2
  if [[ -n "$detentores" ]]; then
    echo "Detentor(es) vigente(s), por id de usuario e desde quando:" >&2
    local item
    IFS=';' read -ra itens <<<"$detentores"
    for item in "${itens[@]}"; do
      echo "  - ${item%%|*} (desde ${item#*|})" >&2
      [[ -z "$primeiro" ]] && primeiro="${item%%|*}"
    done
  fi
  cat >&2 <<TXT
Nada foi gravado.

Se o detentor estiver indisponível ou comprometido, a recuperação documentada na 0014 é manual,
pelo safetycar_migrator, e ESTE SCRIPT NÃO A EXECUTA:
  1) SELECT revogar_permissao_manual('${primeiro:-<id do detentor>}', 'conceder_permissao', '<motivo>');
  2) rode este script de novo (ou: SELECT conceder_permissao_inicial('<id do novo detentor>', '<motivo>');)
Ver docs/BANCO_DE_DADOS.md, "Operadores e permissões da Central".
TXT
  exit 1
}
[[ -n "$DETENTORES" ]] && explica_sc018 "$DETENTORES"

# ---------------------------------------------------------------------------------------------
# 4. Resumo e confirmação
echo "== Primeiro administrador de permissões da Central"
echo "   banco:         $BANCO"
echo "   e-mail:        $EMAIL"
echo "   keycloak_sub:  $SUB"
echo "   motivo:        $MOTIVO"
if (( REAPROVEITA )); then
  echo "   usuário:       já existe (central, ativo, mesmo e-mail): será reaproveitado"
else
  echo "   usuário:       será criado (perfil central, status ativo)"
fi
echo "   ação:          conceder_permissao_inicial (cadastra o operador e concede conceder_permissao)"

if (( SIMULAR )); then
  echo "== SIMULAÇÃO: a transação vai rodar e ser desfeita (ROLLBACK)."
  FIM="ROLLBACK;"
else
  printf 'Para gravar, digite o nome do banco alvo (%s): ' "$BANCO"
  resposta=""
  IFS= read -r resposta || true
  resposta="${resposta%$'\r'}"
  echo
  if [[ "$resposta" != "$BANCO" ]]; then
    echo "Confirmação não confere com o nome do banco. Nada foi gravado."
    exit 2
  fi
  FIM="COMMIT;"
fi

# ---------------------------------------------------------------------------------------------
# 5. Transação única, como safetycar_migrator
SAIDA="$(mktemp)"
trap 'rm -f "$SAIDA"' EXIT
set +e
psql_como safetycar_migrator "$BANCO" -tA -v VERBOSITY=verbose -v SHOW_CONTEXT=never \
  -v email="$EMAIL" -v sub="$SUB" -v motivo="$MOTIVO" -v fim="$FIM" >"$SAIDA" 2>&1 <<'SQL'
BEGIN;
SELECT set_config('primeiro_adm.sub', :'sub', true), set_config('primeiro_adm.email', :'email', true);

-- Revalida dentro da transação (as checagens prévias podem ter mudado desde então).
DO $$
DECLARE
  v_sub   uuid := current_setting('primeiro_adm.sub')::uuid;
  v_email text := current_setting('primeiro_adm.email');
  r record;
BEGIN
  SELECT perfil, status, email = v_email::citext AS email_igual
    INTO r FROM usuario WHERE keycloak_sub = v_sub FOR UPDATE;
  IF FOUND AND (r.perfil <> 'central' OR NOT r.email_igual OR r.status <> 'ativo') THEN
    RAISE EXCEPTION 'o usuário com esse keycloak_sub mudou desde a checagem (perfil %, status %): nada foi gravado',
      r.perfil, r.status;
  END IF;
  IF EXISTS (SELECT 1 FROM usuario WHERE email = v_email::citext AND keycloak_sub <> v_sub) THEN
    RAISE EXCEPTION 'o e-mail já pertence a outro keycloak_sub: nada foi gravado';
  END IF;
END $$;

-- Cria o usuário, se não existir, e audita a criação (sem e-mail na auditoria).
WITH novo AS (
  INSERT INTO usuario (keycloak_sub, email, perfil, status)
  SELECT :'sub'::uuid, :'email', 'central', 'ativo'
   WHERE NOT EXISTS (SELECT 1 FROM usuario WHERE keycloak_sub = :'sub'::uuid)
  RETURNING id, perfil, status
)
INSERT INTO auditoria (acao, entidade, entidade_id, depois)
SELECT 'migrator_criar_usuario_central', 'usuario', id,
       jsonb_build_object('perfil', perfil, 'status', status, 'motivo', :'motivo',
                          'origem', 'db/scripts/primeiro_administrador.sh')
  FROM novo;

SELECT 'usuario_id=' || id FROM usuario WHERE keycloak_sub = :'sub'::uuid;
SELECT 'concessao_id=' || conceder_permissao_inicial(
         (SELECT id FROM usuario WHERE keycloak_sub = :'sub'::uuid), :'motivo');
SELECT 'efetiva=' || operador_tem_permissao(
         (SELECT id FROM usuario WHERE keycloak_sub = :'sub'::uuid), 'conceder_permissao');
:fim
SQL
STATUS=$?
set -e

if (( STATUS != 0 )); then
  CODIGO="$(grep -oE 'ERROR: +[0-9A-Z]{5}' "$SAIDA" | head -n 1 | grep -oE '[0-9A-Z]{5}$' || true)"
  if [[ "$CODIGO" == SC018 ]]; then
    DETENTORES="$(psql_como safetycar_migrator "$BANCO" -tA <<'SQL'
SELECT coalesce(string_agg(operador_id::text || '|' || to_char(concedida_em, 'YYYY-MM-DD HH24:MI:SS TZ'), ';'), '')
  FROM vw_permissao_vigente WHERE permissao_codigo = 'conceder_permissao';
SQL
)"
    explica_sc018 "$DETENTORES"
  fi
  echo "ERRO na transação${CODIGO:+ (SQLSTATE $CODIGO)}; nada foi gravado:" >&2
  grep -E '^(ERROR|ERRO|psql)' "$SAIDA" | head -n 3 >&2
  exit 1
fi

valor() { grep -E "^$1=" "$SAIDA" | head -n 1 | cut -d= -f2-; }
SUFIXO=""; (( SIMULAR )) && SUFIXO=" (simulado; não fica gravado)"
echo "   usuario.id:    $(valor usuario_id)$SUFIXO"
echo "   concessão:     $(valor concessao_id)$SUFIXO"
echo "   efetiva:       $(valor efetiva)"
if (( SIMULAR )); then
  echo "== SIMULAÇÃO concluída: tudo foi desfeito (ROLLBACK). Nada foi gravado."
else
  echo "== Gravado: o usuário é operador da Central, com conceder_permissao vigente (origem inicial)."
fi
