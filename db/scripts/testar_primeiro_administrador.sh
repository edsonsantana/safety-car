#!/usr/bin/env bash
# Testes do db/scripts/primeiro_administrador.sh, fora da suíte padrão.
#
#   bash db/scripts/testar_primeiro_administrador.sh
#
# - Cria os bancos descartáveis safetycar_adm (migrado do zero) e safetycar_adm_vazio (sem a
#   0014), roda os cenários e apaga os dois no fim, mesmo em caso de falha ou Ctrl+C.
#   O banco safetycar não é tocado.
# - Dados fictícios: e-mails @exemplo.invalid e uuids fixos de teste, só nos bancos descartáveis.
# - "Nada gravado" é conferido pela contagem de usuario, operador_central, permissao_concessao,
#   permissao_revogacao e auditoria antes e depois. Não há sequências no schema (todas as chaves
#   são uuid), então uma simulação desfeita não deixa nenhum rastro.
# - Cada verificação imprime OK ou FALHOU; o script sai com código 1 se alguma falhar.
set -euo pipefail
source "$(dirname "$0")/_comum.sh"

BANCO=safetycar_adm
VAZIO=safetycar_adm_vazio
SCRIPT=db/scripts/primeiro_administrador.sh

exige_banco_saudavel
if [[ "$(psql_como postgres postgres -tA -c "SELECT count(*) FROM pg_roles WHERE rolname = 'safetycar_central'")" != "1" ]]; then
  echo "ERRO: o papel safetycar_central não existe (migração 0014). Rode: bash db/scripts/criar_papeis.sh" >&2
  exit 1
fi

TMP="$(mktemp -d)"
limpar() {
  local status=$? b
  trap - EXIT
  for b in "$BANCO" "$VAZIO"; do
    if psql_como postgres postgres -c "DROP DATABASE IF EXISTS $b WITH (FORCE)" >/dev/null 2>&1; then
      echo "== $b apagado"
    else
      echo "!! não foi possível apagar $b; apague à mão: DROP DATABASE $b WITH (FORCE)" >&2
      status=1
    fi
  done
  rm -rf "$TMP"
  exit "$status"
}
trap limpar EXIT
trap 'exit 130' INT TERM

sql() { psql_como postgres "$BANCO" -tA "$@"; }

FALHAS=0; TOTAL=0
ok()     { TOTAL=$((TOTAL + 1)); echo "   OK: $*"; }
falhou() { TOTAL=$((TOTAL + 1)); FALHAS=$((FALHAS + 1)); echo "   FALHOU: $*"; }
confere() { if [[ "$(sql -c "SELECT ($2)")" == t ]]; then ok "$1"; else falhou "$1 (estado diferente do esperado)"; fi; }

# roda <resposta digitada> <argumentos...>: roda o script com a resposta na entrada padrão.
# Saída em $TMP/saida e código em $STATUS.
roda() {
  local resposta="$1"; shift
  set +e
  printf '%s\n' "$resposta" | bash "$SCRIPT" "$@" >"$TMP/saida" 2>&1
  STATUS=$?
  set -e
}
saida_tem() { grep -qiE -- "$1" "$TMP/saida"; }
mostra_saida() { sed 's/^/      | /' "$TMP/saida" | head -n 12; }

CONTAGEM="SELECT (SELECT count(*) FROM usuario) || '/' || (SELECT count(*) FROM operador_central) || '/' ||
                 (SELECT count(*) FROM permissao_concessao) || '/' || (SELECT count(*) FROM permissao_revogacao) || '/' ||
                 (SELECT count(*) FROM auditoria)"
contagem() { sql -c "$CONTAGEM"; }

# espera_recusa <descrição> <status esperado> <trecho da mensagem> <resposta> <argumentos...>
espera_recusa() {
  local desc="$1" st="$2" trecho="$3" resp="$4"; shift 4
  local antes depois
  antes="$(contagem)"
  roda "$resp" "$@"
  depois="$(contagem)"
  if [[ "$STATUS" == "$st" ]] && saida_tem "$trecho" && [[ "$antes" == "$depois" ]]; then
    ok "$desc"
  else
    falhou "$desc (status $STATUS, esperado $st; contagem $antes -> $depois; mensagem esperada: $trecho)"
    mostra_saida
  fi
}

# ---------------------------------------------------------------------------------------------
echo "== Recriando $BANCO e $VAZIO"
psql_como postgres postgres <<SQL
DROP DATABASE IF EXISTS $BANCO WITH (FORCE);
DROP DATABASE IF EXISTS $VAZIO WITH (FORCE);
CREATE DATABASE $BANCO OWNER safetycar_migrator TEMPLATE template0 ENCODING 'UTF8';
CREATE DATABASE $VAZIO OWNER safetycar_migrator TEMPLATE template0 ENCODING 'UTF8';
REVOKE ALL ON DATABASE $BANCO FROM PUBLIC;
REVOKE ALL ON DATABASE $VAZIO FROM PUBLIC;
SQL
echo "== Migrando $BANCO do zero"
bash db/scripts/migrar.sh "$BANCO" | tail -n 1

# Dados fictícios.
A_EMAIL=adm-a@exemplo.invalid;  A_SUB=00000000-0000-4000-8000-0000000ad001
B_EMAIL=adm-b@exemplo.invalid;  B_SUB=00000000-0000-4000-8000-0000000ad002
T_EMAIL=tomador@exemplo.invalid; T_SUB=00000000-0000-4000-8000-0000000ad003
R_EMAIL=adm-r@exemplo.invalid;  R_SUB=00000000-0000-4000-8000-0000000ad004   # já existe, reaproveitado
E_EMAIL=adm-e@exemplo.invalid;  E_SUB=00000000-0000-4000-8000-0000000ad005   # já existe, e-mail diverge
P_EMAIL=adm-p@exemplo.invalid;  P_SUB=00000000-0000-4000-8000-0000000ad006   # já existe, status pendente
NOVO_SUB=00000000-0000-4000-8000-0000000ad099
MOTIVO="[TESTE] primeiro administrador: motivo do cenário"

confere "o schema não tem sequências (simulação desfeita não consome nada)" \
  "NOT EXISTS (SELECT 1 FROM pg_sequences WHERE schemaname = 'public')"

# ---------------------------------------------------------------------------------------------
echo "== Cenário 1: argumentos inválidos"
espera_recusa "e-mail sem @ é recusado"            1 "e-mail com formato inválido" "$BANCO" --email sem-arroba.exemplo.invalid --sub "$A_SUB" --banco "$BANCO"
espera_recusa "e-mail com espaço é recusado"       1 "e-mail com formato inválido" "$BANCO" --email "a b@exemplo.invalid" --sub "$A_SUB" --banco "$BANCO"
espera_recusa "uuid curto é recusado"              1 "keycloak_sub com formato inválido" "$BANCO" --email "$A_EMAIL" --sub 1234 --banco "$BANCO"
espera_recusa "uuid com caractere fora de hex"     1 "keycloak_sub com formato inválido" "$BANCO" --email "$A_EMAIL" --sub 00000000-0000-4000-8000-00000000zzzz --banco "$BANCO"
for b in postgres template0 template1; do
  espera_recusa "banco $b é recusado" 1 "não é um banco da aplicação" "$b" --email "$A_EMAIL" --sub "$A_SUB" --banco "$b"
done
espera_recusa "nome de banco com caractere inválido" 1 "nome de banco inválido" "x" --email "$A_EMAIL" --sub "$A_SUB" --banco "x;drop"
espera_recusa "sem --sub é recusado"               1 "informe --sub" "$BANCO" --email "$A_EMAIL" --banco "$BANCO"
espera_recusa "motivo vazio é recusado"            1 "motivo não pode ser vazio" "$BANCO" --email "$A_EMAIL" --sub "$A_SUB" --banco "$BANCO" --motivo "   "

echo "== Cenário 2: banco inexistente e banco sem a 0014"
espera_recusa "banco inexistente é recusado"       1 "não existe" "safetycar_adm_inexistente" --email "$A_EMAIL" --sub "$A_SUB" --banco safetycar_adm_inexistente
espera_recusa "banco sem schema_migracao é recusado" 1 "não tem schema_migracao" "$VAZIO" --email "$A_EMAIL" --sub "$A_SUB" --banco "$VAZIO"
psql_como safetycar_migrator "$VAZIO" -q <<'SQL'
CREATE TABLE schema_migracao (versao text PRIMARY KEY, arquivo text, sha256 text, aplicada_em timestamptz DEFAULT now());
INSERT INTO schema_migracao (versao, arquivo, sha256) VALUES ('0013', '0013_ficticia.sql', 'teste');
SQL
espera_recusa "banco com migrações só até a 0013 é recusado" 1 "não tem a migração 0014" "$VAZIO" --email "$A_EMAIL" --sub "$A_SUB" --banco "$VAZIO"

echo "== Cenário 3: --simular não grava nada"
espera_recusa "simulação termina em ROLLBACK, sem linhas novas (nem auditoria)" 0 "SIMULAÇÃO concluída" "" \
  --email "$A_EMAIL" --sub "$A_SUB" --banco "$BANCO" --motivo "$MOTIVO" --simular
if saida_tem "efetiva: +t"; then ok "a simulação mostra que a permissão seria efetiva"; else falhou "a simulação não mostrou o resultado"; mostra_saida; fi

echo "== Cenário 4: sem a confirmação certa, nada é gravado"
espera_recusa "resposta vazia encerra sem gravar"       2 "Nada foi gravado" ""          --email "$A_EMAIL" --sub "$A_SUB" --banco "$BANCO" --motivo "$MOTIVO"
espera_recusa "resposta CONFIRMO encerra sem gravar"    2 "Nada foi gravado" "CONFIRMO"  --email "$A_EMAIL" --sub "$A_SUB" --banco "$BANCO" --motivo "$MOTIVO"
espera_recusa "nome de OUTRO banco encerra sem gravar"  2 "Nada foi gravado" "safetycar" --email "$A_EMAIL" --sub "$A_SUB" --banco "$BANCO" --motivo "$MOTIVO"

echo "== Cenário 5: com o nome do banco digitado, grava usuário, operador e concessão"
roda "$BANCO" --email "$A_EMAIL" --sub "$A_SUB" --banco "$BANCO" --motivo "$MOTIVO"
if [[ "$STATUS" == 0 ]] && saida_tem "Gravado:"; then ok "o script concluiu (status 0)"; else falhou "o script não concluiu (status $STATUS)"; mostra_saida; fi
A_ID="$(sql -c "SELECT id FROM usuario WHERE keycloak_sub = '$A_SUB'")"
confere "usuário criado com perfil central, status ativo, e-mail certo e email_verificado_em nulo" \
  "EXISTS (SELECT 1 FROM usuario WHERE keycloak_sub = '$A_SUB' AND perfil = 'central' AND status = 'ativo'
            AND email = '$A_EMAIL' AND email_verificado_em IS NULL)"
confere "operador criado e ativo" "EXISTS (SELECT 1 FROM operador_central WHERE usuario_id = '$A_ID' AND ativo)"
confere "concessão vigente de conceder_permissao, origem inicial, efetiva, com o motivo" \
  "EXISTS (SELECT 1 FROM vw_permissao_vigente WHERE operador_id = '$A_ID' AND permissao_codigo = 'conceder_permissao'
            AND origem = 'inicial' AND efetiva AND motivo = '$MOTIVO')"
confere "auditoria da criação do usuário: papel_bd safetycar_migrator, motivo gravado, sem ator" \
  "EXISTS (SELECT 1 FROM auditoria WHERE acao = 'migrator_criar_usuario_central' AND entidade = 'usuario'
            AND entidade_id = '$A_ID' AND papel_bd = 'safetycar_migrator' AND depois->>'motivo' = '$MOTIVO'
            AND depois->>'perfil' = 'central' AND depois->>'status' = 'ativo' AND ator_usuario_id IS NULL)"
confere "auditoria da concessão: papel_bd safetycar_migrator e motivo gravado" \
  "EXISTS (SELECT 1 FROM auditoria WHERE entidade = 'permissao_concessao' AND acao = 'parametrizacao_insert'
            AND papel_bd = 'safetycar_migrator' AND depois->>'motivo' = '$MOTIVO' AND depois->>'operador_id' = '$A_ID')"
confere "auditoria do operador: papel_bd safetycar_migrator" \
  "EXISTS (SELECT 1 FROM auditoria WHERE entidade = 'operador_central' AND acao = 'parametrizacao_insert'
            AND papel_bd = 'safetycar_migrator' AND depois->>'usuario_id' = '$A_ID')"
confere "o e-mail não aparece em nenhuma linha de auditoria" \
  "NOT EXISTS (SELECT 1 FROM auditoria WHERE coalesce(depois::text, '') || coalesce(antes::text, '') ILIKE '%exemplo.invalid%')"

echo "== Cenário 6: segunda execução é recusada (SC018), com o caminho de recuperação"
espera_recusa "outro usuário: recusado com SC018, nada gravado" 1 "SC018" "$BANCO" --email "$B_EMAIL" --sub "$B_SUB" --banco "$BANCO"
if saida_tem "revogar_permissao_manual\('$A_ID'" && saida_tem "NÃO A EXECUTA"; then
  ok "a mensagem mostra o detentor e o caminho de recuperação, sem executá-lo"
else
  falhou "a mensagem não mostrou o caminho de recuperação"; mostra_saida
fi
confere "o usuário B não foi criado e a concessão de A segue vigente" \
  "NOT EXISTS (SELECT 1 FROM usuario WHERE keycloak_sub = '$B_SUB')
   AND (SELECT count(*) FROM vw_permissao_vigente WHERE permissao_codigo = 'conceder_permissao') = 1"
espera_recusa "o mesmo usuário de novo: também recusado com SC018" 1 "SC018" "$BANCO" --email "$A_EMAIL" --sub "$A_SUB" --banco "$BANCO"
espera_recusa "simulação com detentor vigente também é recusada" 1 "SC018" "" --email "$B_EMAIL" --sub "$B_SUB" --banco "$BANCO" --simular

echo "== Cenário 7: usuário já existente com outro perfil"
sql >/dev/null -c "INSERT INTO usuario (keycloak_sub, email, perfil, status) VALUES ('$T_SUB', '$T_EMAIL', 'tomador', 'ativo')"
espera_recusa "mesmo sub com perfil tomador: aborta, nada gravado" 1 "perfil 'tomador'" "$BANCO" --email "$T_EMAIL" --sub "$T_SUB" --banco "$BANCO"

echo "== Cenário 8: e-mail já usado por outro sub"
espera_recusa "e-mail de A com outro sub: aborta, nada gravado" 1 "já pertence a outro usuário" "$BANCO" --email "$A_EMAIL" --sub "$NOVO_SUB" --banco "$BANCO"
espera_recusa "e-mail com maiúsculas também é reconhecido" 1 "já pertence a outro usuário" "$BANCO" --email "ADM-A@exemplo.invalid" --sub "$NOVO_SUB" --banco "$BANCO"

echo "== Cenário 9: reaproveitamento de usuário central existente (sem detentor vigente)"
psql_como safetycar_migrator "$BANCO" -tA >/dev/null \
  -c "SELECT revogar_permissao_manual('$A_ID', 'conceder_permissao', '[TESTE] primeiro administrador: abre espaço para o cenário 9')"
confere "não há mais detentor vigente" \
  "NOT EXISTS (SELECT 1 FROM vw_permissao_vigente WHERE permissao_codigo = 'conceder_permissao')"
sql >/dev/null <<SQL
INSERT INTO usuario (keycloak_sub, email, perfil, status) VALUES
  ('$R_SUB', '$R_EMAIL', 'central', 'ativo'),
  ('$E_SUB', '$E_EMAIL', 'central', 'ativo'),
  ('$P_SUB', '$P_EMAIL', 'central', 'pendente');
SQL
espera_recusa "mesmo sub e perfil central, mas e-mail diferente: aborta" 1 "OUTRO e-mail" "$BANCO" \
  --email outro-email@exemplo.invalid --sub "$E_SUB" --banco "$BANCO"
espera_recusa "mesmo sub, central, mesmo e-mail, mas status pendente: aborta" 1 "status 'pendente'" "$BANCO" \
  --email "$P_EMAIL" --sub "$P_SUB" --banco "$BANCO"
antes_usuarios="$(sql -c "SELECT count(*) FROM usuario")"
roda "$BANCO" --email "$R_EMAIL" --sub "$R_SUB" --banco "$BANCO" --motivo "$MOTIVO"
if [[ "$STATUS" == 0 ]] && saida_tem "será reaproveitado"; then ok "usuário existente reaproveitado (status 0)"; else falhou "reaproveitamento falhou (status $STATUS)"; mostra_saida; fi
R_ID="$(sql -c "SELECT id FROM usuario WHERE keycloak_sub = '$R_SUB'")"
confere "nenhum usuário novo e nenhuma auditoria de criação para o reaproveitado" \
  "(SELECT count(*) FROM usuario) = $antes_usuarios
   AND NOT EXISTS (SELECT 1 FROM auditoria WHERE acao = 'migrator_criar_usuario_central' AND entidade_id = '$R_ID')"
confere "operador e concessão vigente efetiva criados para o reaproveitado" \
  "EXISTS (SELECT 1 FROM operador_central WHERE usuario_id = '$R_ID' AND ativo)
   AND EXISTS (SELECT 1 FROM vw_permissao_vigente WHERE operador_id = '$R_ID' AND permissao_codigo = 'conceder_permissao' AND efetiva)"
confere "E e P continuam sem operador nem concessão" \
  "NOT EXISTS (SELECT 1 FROM operador_central o JOIN usuario u ON u.id = o.usuario_id WHERE u.keycloak_sub IN ('$E_SUB', '$P_SUB'))"

# ---------------------------------------------------------------------------------------------
echo
if (( FALHAS > 0 )); then
  echo "== $FALHAS de $TOTAL verificações FALHARAM."
  exit 1
fi
echo "== Todas as $TOTAL verificações do primeiro administrador passaram."
