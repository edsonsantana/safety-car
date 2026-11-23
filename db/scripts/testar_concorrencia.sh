#!/usr/bin/env bash
# Testes de concorrência da 0014 a 0019 com DUAS SESSÕES SIMULTÂNEAS de verdade.
# Fora da suíte padrão (o testar.sh roda uma sessão por arquivo e não cobre isto).
#
#   bash db/scripts/testar_concorrencia.sh
#
# - Cria o banco descartável safetycar_conc, aplica as migrações do zero, roda os cenários e
#   apaga o banco no fim, mesmo em caso de falha ou Ctrl+C. O banco safetycar não é tocado.
# - Cada cenário: a sessão A faz a ação e segura a transação aberta (pg_sleep); o script espera
#   A estar segurando, dispara B e CONFERE no pg_stat_activity que B ficou bloqueada esperando
#   lock. Só então A faz COMMIT. Se B não esperar, o cenário falha (não houve concorrência).
# - A Central entra por TCP (-h db, dentro do contêiner), onde o pg_hba exige scram-sha-256: a
#   senha do .env (SAFETYCAR_CENTRAL_PASSWORD) vai ao psql por variável de ambiente, nunca pela
#   linha de comando, e nunca é impressa. O migrator e o postgres entram pelo socket local.
# - Timeouts: lock_timeout e statement_timeout em cada sessão, timeout em cada processo e limite
#   de 10 s em cada espera. deadlock_timeout fica no padrão (1 s): um 40P01 apareceria de fato.
# - Dados fictícios (e-mails @exemplo.invalid, uuids fixos de teste), só no banco descartável.
# - Cada cenário imprime OK ou FALHOU; o script sai com código 1 se algum falhar.
set -euo pipefail
source "$(dirname "$0")/_comum.sh"

BANCO=safetycar_conc
SEGURA=4   # segundos que a sessão A segura a transação aberta

case "$BANCO" in safetycar|postgres|safetycar_teste) echo "ERRO: banco alvo inválido: $BANCO" >&2; exit 1;; esac

exige_banco_saudavel
if [[ "$(psql_como postgres postgres -tA -c "SELECT count(*) FROM pg_roles WHERE rolname = 'safetycar_central'")" != "1" ]]; then
  echo "ERRO: o papel safetycar_central não existe (migração 0014). Rode: bash db/scripts/criar_papeis.sh" >&2
  exit 1
fi
SC_CENTRAL_PW="$(le_env SAFETYCAR_CENTRAL_PASSWORD)"
if [[ -z "$SC_CENTRAL_PW" ]]; then
  echo "ERRO: defina SAFETYCAR_CENTRAL_PASSWORD no .env (veja .env.example)." >&2
  exit 1
fi

TMP="$(mktemp -d)"
limpar() {
  local status=$?
  trap - EXIT
  local pids; pids="$(jobs -p)"
  [[ -n "$pids" ]] && kill $pids 2>/dev/null || true
  wait 2>/dev/null || true
  if psql_como postgres postgres -c "DROP DATABASE IF EXISTS $BANCO WITH (FORCE)" >/dev/null 2>&1; then
    echo "== $BANCO apagado"
  else
    echo "!! não foi possível apagar $BANCO; apague à mão: DROP DATABASE $BANCO WITH (FORCE)" >&2
    status=1
  fi
  rm -rf "$TMP"
  exit "$status"
}
trap limpar EXIT
trap 'exit 130' INT TERM

# SQL como postgres no banco descartável (uma linha por resultado, sem cabeçalho).
sql() { psql_como postgres "$BANCO" -tA "$@"; }

# sessao <nome> <papel> [senha]: roda em segundo plano o SQL recebido no stdin.
# Saída em $TMP/<nome>.out e código de saída em $TMP/<nome>.status (124 = timeout).
sessao() {
  local nome="$1" papel="$2" senha="${3:-$SC_CENTRAL_PW}"
  cat >"$TMP/$nome.sql"
  (
    set +e
    export PGAPPNAME="conc_$nome" PGOPTIONS="-c lock_timeout=15s -c statement_timeout=30s"
    envs=(-e PGAPPNAME -e PGOPTIONS)
    destino=(-U "$papel")
    if [[ "$papel" == safetycar_central ]]; then
      export PGPASSWORD="$senha"
      envs+=(-e PGPASSWORD)
      destino=(-h db -U safetycar_central)
    fi
    MSYS_NO_PATHCONV=1 timeout 60 docker compose exec -T "${envs[@]}" db \
      psql -X -q -tA -v ON_ERROR_STOP=1 -v VERBOSITY=sqlstate "${destino[@]}" -d "$BANCO" \
      <"$TMP/$nome.sql" >"$TMP/$nome.out" 2>&1
    echo $? >"$TMP/$nome.status"
  ) &
}

sqlstate_de() { grep -oE 'ERROR: +[0-9A-Z]{5}' "$1" 2>/dev/null | head -n 1 | grep -oE '[0-9A-Z]{5}$' || true; }
ultima_linha() { grep -v '^$' "$1" 2>/dev/null | tail -n 1 || true; }

# corrida <papel A> <SQL de A> <papel B> <SQL de B>
# A: BEGIN; <SQL de A>; pg_sleep(SEGURA); COMMIT.  B: <SQL de B> (autocommit), disparada com A segurando.
# Preenche ESPERA_B (evento de espera de B, vazio se B não esperou) e CORRIDA_ERRO.
corrida() {
  rm -f "$TMP"/A.* "$TMP"/B.*
  ESPERA_B=""; CORRIDA_ERRO=""
  sessao A "$1" <<SQL
BEGIN;
$2
SELECT pg_sleep($SEGURA);
COMMIT;
SQL
  if [[ "$(sql -c "SELECT conc_espera_segurando('conc_A')")" != t ]]; then
    wait
    CORRIDA_ERRO="A não chegou a segurar a transação: $(ultima_linha "$TMP/A.out")"
    return 0
  fi
  sessao B "$3" <<<"$4"
  ESPERA_B="$(sql -c "SELECT conc_espera_lock('conc_B')")"
  wait
}

# confere_sessoes <esperado em B: SQLSTATE ou "ok">: devolve 1 e preenche MOTIVO se não bateu.
confere_sessoes() {
  local esperado="$1" st_a st_b erro_a erro_b
  MOTIVO=""
  if [[ -n "$CORRIDA_ERRO" ]]; then MOTIVO="$CORRIDA_ERRO"; return 1; fi
  st_a="$(cat "$TMP/A.status" 2>/dev/null || echo '?')"
  st_b="$(cat "$TMP/B.status" 2>/dev/null || echo '?')"
  erro_a="$(sqlstate_de "$TMP/A.out")"
  erro_b="$(sqlstate_de "$TMP/B.out")"
  if [[ "$st_a" != 0 ]]; then
    MOTIVO="A terminou com status $st_a${erro_a:+ (SQLSTATE $erro_a)}: $(ultima_linha "$TMP/A.out")"; return 1
  fi
  if [[ -z "$ESPERA_B" ]]; then
    MOTIVO="B não ficou esperando lock enquanto A segurava a transação (sem concorrência real)"; return 1
  fi
  if [[ "$erro_b" == 40P01 ]]; then MOTIVO="B terminou em DEADLOCK (40P01): $(ultima_linha "$TMP/B.out")"; return 1; fi
  if [[ "$esperado" == ok ]]; then
    [[ "$st_b" == 0 ]] && return 0
    MOTIVO="B devia concluir, mas terminou com status $st_b${erro_b:+ (SQLSTATE $erro_b)}: $(ultima_linha "$TMP/B.out")"; return 1
  fi
  [[ "$erro_b" == "$esperado" ]] && return 0
  MOTIVO="B devia terminar em $esperado, mas terminou com status $st_b${erro_b:+ (SQLSTATE $erro_b)}: $(ultima_linha "$TMP/B.out")"
  return 1
}

FALHAS=0; TOTAL=0
ok()     { TOTAL=$((TOTAL + 1)); echo "   OK: $*"; }
falhou() { TOTAL=$((TOTAL + 1)); FALHAS=$((FALHAS + 1)); echo "   FALHOU: $*"; }
# verdade <SQL boolean>: 0 se o banco responder true.
verdade() { [[ "$(sql -c "SELECT ($1)")" == t ]]; }
# confere <descrição> <SQL boolean>
confere() { if verdade "$2"; then ok "$1"; else falhou "$1 (estado final diferente do esperado)"; fi; }

# ---------------------------------------------------------------------------------------------
echo "== Recriando $BANCO"
psql_como postgres postgres <<SQL
DROP DATABASE IF EXISTS $BANCO WITH (FORCE);
CREATE DATABASE $BANCO OWNER safetycar_migrator TEMPLATE template0 ENCODING 'UTF8';
REVOKE ALL ON DATABASE $BANCO FROM PUBLIC;
SQL

echo "== Migrando $BANCO do zero"
bash db/scripts/migrar.sh "$BANCO" | tail -n 1

# Utilitários de espera (só neste banco descartável). pg_stat_clear_snapshot a cada volta:
# senão o pg_stat_activity fica congelado dentro da transação.
sql >/dev/null <<'SQL'
CREATE FUNCTION conc_espera_segurando(p_app text) RETURNS boolean
LANGUAGE plpgsql AS $$
DECLARE v_fim timestamptz := clock_timestamp() + interval '10 s';
BEGIN
  LOOP
    PERFORM pg_stat_clear_snapshot();
    IF EXISTS (SELECT 1 FROM pg_stat_activity
                WHERE application_name = p_app AND state = 'active' AND query LIKE 'SELECT pg_sleep%') THEN
      RETURN true;
    END IF;
    IF clock_timestamp() > v_fim THEN RETURN false; END IF;
    PERFORM pg_sleep(0.05);
  END LOOP;
END $$;

CREATE FUNCTION conc_espera_lock(p_app text) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE v_fim timestamptz := clock_timestamp() + interval '10 s'; v text;
BEGIN
  LOOP
    PERFORM pg_stat_clear_snapshot();
    SELECT wait_event_type || '/' || wait_event INTO v
      FROM pg_stat_activity WHERE application_name = p_app AND wait_event_type = 'Lock' LIMIT 1;
    IF v IS NOT NULL THEN RETURN v; END IF;
    IF clock_timestamp() > v_fim THEN RETURN NULL; END IF;
    PERFORM pg_sleep(0.05);
  END LOOP;
END $$;
SQL

# Usuários fictícios da Central.
U1=00000000-0000-4000-8000-00000c0c0001   # 1ª concessão inicial
U2=00000000-0000-4000-8000-00000c0c0002   # concorre com U1
U3=00000000-0000-4000-8000-00000c0c0003   # concessão inicial depois da recuperação
S1=00000000-0000-4000-8000-00000c0c0011   # solicitante
S2=00000000-0000-4000-8000-00000c0c0012   # solicitante
P1=00000000-0000-4000-8000-00000c0c0021   # aprovador
P2=00000000-0000-4000-8000-00000c0c0022   # aprovador
OP=00000000-0000-4000-8000-00000c0c0031   # recebe concessões no cenário 5

sql >/dev/null <<SQL
INSERT INTO usuario (id, keycloak_sub, email, perfil, status)
SELECT u::uuid, gen_random_uuid(), 'conc-' || right(u, 4) || '@exemplo.invalid', 'central', 'ativo'
  FROM unnest(ARRAY['$U1','$U2','$U3','$S1','$S2','$P1','$P2','$OP']) u;
SQL

# ---------------------------------------------------------------------------------------------
echo "== Pré-condição: login da Central por TCP com senha"
sessao L safetycar_central <<<"SELECT session_user || '|' || (inet_client_addr() IS NOT NULL AND host(inet_client_addr()) <> '127.0.0.1');"
wait
if [[ "$(cat "$TMP/L.status")" == 0 && "$(ultima_linha "$TMP/L.out")" == "safetycar_central|true" ]]; then
  ok "safetycar_central conectou por TCP (fora de 127.0.0.1, onde o pg_hba exige scram-sha-256)"
else
  falhou "login da Central por TCP: $(ultima_linha "$TMP/L.out")"
  echo "!! sem o login da Central não há como rodar os cenários" >&2
  exit 1
fi
sessao L safetycar_central "senha-errada-so-para-o-teste-de-concorrencia" <<<"SELECT 1;"
wait
if [[ "$(cat "$TMP/L.status")" != 0 ]] && grep -q 'password authentication failed' "$TMP/L.out"; then
  ok "senha errada é recusada (a conexão TCP exige senha de fato)"
else
  falhou "a conexão TCP aceitou senha errada ou falhou por outro motivo: $(ultima_linha "$TMP/L.out")"
fi

VIGENTE_CONCEDER="SELECT count(*) FROM vw_permissao_vigente WHERE permissao_codigo = 'conceder_permissao'"

# ---------------------------------------------------------------------------------------------
echo "== Cenário 1a: duas concessões iniciais simultâneas (usuários diferentes)"
corrida safetycar_migrator "SELECT conceder_permissao_inicial('$U1', '[TESTE] conc 1a: A');" \
        safetycar_migrator "SELECT conceder_permissao_inicial('$U2', '[TESTE] conc 1a: B');"
if confere_sessoes SC018; then
  ok "A concedeu; B esperou ($ESPERA_B) e terminou em SC018, não em 40P01"
  confere "uma única concessão vigente de conceder_permissao, a de U1" \
    "($VIGENTE_CONCEDER) = 1 AND EXISTS (SELECT 1 FROM vw_permissao_vigente WHERE permissao_codigo = 'conceder_permissao' AND operador_id = '$U1')"
else
  falhou "1a: $MOTIVO"
fi

echo "== Cenário 1b: duas concessões iniciais simultâneas (o mesmo usuário), depois da recuperação manual"
psql_como safetycar_migrator "$BANCO" -tA >/dev/null \
  -c "SELECT revogar_permissao_manual('$U1', 'conceder_permissao', '[TESTE] conc 1b: recuperação')"
corrida safetycar_migrator "SELECT conceder_permissao_inicial('$U3', '[TESTE] conc 1b: A');" \
        safetycar_migrator "SELECT conceder_permissao_inicial('$U3', '[TESTE] conc 1b: B');"
if confere_sessoes SC018; then
  ok "A concedeu; B esperou ($ESPERA_B) e terminou em SC018, não em 40P01"
  confere "uma única concessão vigente de conceder_permissao, a de U3" \
    "($VIGENTE_CONCEDER) = 1 AND EXISTS (SELECT 1 FROM vw_permissao_vigente WHERE permissao_codigo = 'conceder_permissao' AND operador_id = '$U3')"
else
  falhou "1b: $MOTIVO"
fi

# Equipe e regras de taxa definidas (combinações fora da carga inicial, que está toda a definir).
sql >/dev/null <<SQL
SELECT conceder_permissao('$U3', '$U1', 'conceder_permissao', '[TESTE] conc: segundo detentor');
SELECT cadastrar_operador('$U3', u::uuid, '[TESTE] conc: equipe')
  FROM unnest(ARRAY['$S1','$S2','$P1','$P2','$OP']) u;
SELECT conceder_permissao('$U3', p::uuid, 'aprovar_reajuste_taxa', '[TESTE] conc: aprovador')
  FROM unnest(ARRAY['$P1','$P2']) p;
-- Desde a 0019, solicitar exige solicitar_reajuste_taxa.
SELECT conceder_permissao('$U3', s::uuid, 'solicitar_reajuste_taxa', '[TESTE] conc: solicitante')
  FROM unnest(ARRAY['$S1','$S2']) s;
INSERT INTO regra_taxa (tipo_parceiro_codigo, servico_codigo, uf, componente, unidade, valor, situacao, observacao) VALUES
  ('chaveiro', 'guincho_leve',   NULL, 'base',   'centavos', 20000, 'definido', '[TESTE] conc 2'),
  ('chaveiro', 'pneu',           NULL, 'base',   'centavos', 10005, 'definido', '[TESTE] conc 3'),
  ('chaveiro', 'pneu',           NULL, 'minimo', 'centavos',  5000, 'definido', '[TESTE] conc 3'),
  ('chaveiro', 'bateria',        NULL, 'base',   'centavos', 30000, 'definido', '[TESTE] conc 4'),
  ('chaveiro', 'combustivel',    NULL, 'base',   'centavos', 40000, 'definido', '[TESTE] conc 4'),
  ('chaveiro', 'mecanica_movel', NULL, 'base',   'centavos', 50000, 'definido', '[TESTE] conc 6');
SQL

# Desde a 0019: percentual (em %), início na aprovação, um lote em aberto por escopo (SC024).
# sol_sql <ator> <percentual> <serviço> <componentes>: o SQL da solicitação (chaveiro, nacional).
sol_sql() {
  echo "SELECT solicitar_reajuste_taxa('$1', $2, '{chaveiro}', '{$3}', NULL, NULL, true, '{$4}', false, '[TESTE] conc: lote');"
}
# solicita <ator> <percentual> <serviço> <componentes>: imprime o id do lote.
solicita() { sql -c "$(sol_sql "$@")"; }
L2="$(solicita "$S1" 10 guincho_leve base)"
L3A="$(solicita "$S1" 10 pneu base,minimo)"
L4A="$(solicita "$S1" 10 bateria base)"
L4B="$(solicita "$S2" 10 combustivel base)"
L6="$(solicita "$S1" 10 mecanica_movel base)"

aprova() { echo "SELECT aprovar_reajuste_taxa('$1', '$2', '[TESTE] conc: aprovação');"; }
vigente() {  # vigente <serviço> <componente>: valor da regra nacional vigente agora
  echo "(SELECT valor FROM regra_taxa_vigente('chaveiro', '$1', NULL, '$2'))"
}

# ---------------------------------------------------------------------------------------------
echo "== Cenário 2: duas aprovações simultâneas do MESMO lote"
corrida safetycar_central "$(aprova "$P1" "$L2")" safetycar_central "$(aprova "$P2" "$L2")"
if confere_sessoes SC020; then
  ok "P1 aprovou; P2 esperou ($ESPERA_B) e terminou em SC020"
  confere "uma única decisão (aprovado por P1) e uma única nova versão: 20000 vira 22000" \
    "(SELECT count(*) FROM reajuste_taxa_decisao WHERE reajuste_id = '$L2') = 1
     AND (SELECT decidido_por = '$P1' AND situacao = 'aprovado' FROM reajuste_taxa_decisao WHERE reajuste_id = '$L2')
     AND (SELECT count(*) FROM regra_taxa WHERE reajuste_id = '$L2') = 1
     AND $(vigente guincho_leve base) = 22000"
else
  falhou "2: $MOTIVO"
fi

# Desde a 0019 não há dois lotes em aberto com escopo sobreposto. O cenário 3 passou a ser:
# a aprovação de L3A concorre com a SOLICITAÇÃO de L3B (sobreposto). L3B espera o advisory
# lock e, como L3A já foi decidido, é aceito; depois é aprovado e calcula sobre o valor novo.
echo "== Cenário 3: aprovação de um lote concorrendo com a solicitação de outro lote sobreposto"
corrida safetycar_central "$(aprova "$P1" "$L3A")" safetycar_central "$(sol_sql "$S2" 5 pneu base)"
if confere_sessoes ok; then
  ok "as duas concluíram; a solicitação esperou ($ESPERA_B) a aprovação, em série"
  L3B="$(sql -c "SELECT id FROM reajuste_taxa WHERE solicitado_por = '$S2' AND servicos = '{pneu}' AND percentual_bp = 500")"
  sql >/dev/null -c "SELECT aprovar_reajuste_taxa('$P2', '$L3B', '[TESTE] conc 3: aprovação de L3B')"
  confere "L3B recalculou sobre o valor já reajustado: base 10005 → 11006 (+10%, 0,5 sobe) → 11556 (+5%), e não 10505" \
    "$(vigente pneu base) = 11556"
  confere "mínimo só com o primeiro lote: 5000 → 5500" "$(vigente pneu minimo) = 5500"
  confere "a base vigente veio de L3B e substituiu a regra criada por L3A" \
    "(SELECT n.reajuste_id = '$L3B' AND o.reajuste_id = '$L3A'
        FROM regra_taxa_vigente('chaveiro', 'pneu', NULL, 'base') n JOIN regra_taxa o ON o.id = n.regra_origem_id)"
  confere "sem reajuste parcial: L3A criou 2 versões, L3B 1, e as decisões registram o mesmo" \
    "(SELECT count(*) FROM regra_taxa WHERE reajuste_id = '$L3A') = 2
     AND (SELECT count(*) FROM regra_taxa WHERE reajuste_id = '$L3B') = 1
     AND (SELECT regras_afetadas FROM reajuste_taxa_decisao WHERE reajuste_id = '$L3A') = 2
     AND (SELECT regras_afetadas FROM reajuste_taxa_decisao WHERE reajuste_id = '$L3B') = 1"
  confere "vigências contíguas: cada regra nova começa exatamente no fim da que substituiu" \
    "NOT EXISTS (SELECT 1 FROM regra_taxa n JOIN regra_taxa o ON o.id = n.regra_origem_id
                  WHERE n.reajuste_id IN ('$L3A', '$L3B') AND o.fim_vigencia IS DISTINCT FROM n.inicio_vigencia)"
else
  falhou "3: $MOTIVO"
fi

echo "== Cenário 4: aprovações simultâneas de lotes com escopos DISJUNTOS"
corrida safetycar_central "$(aprova "$P1" "$L4A")" safetycar_central "$(aprova "$P2" "$L4B")"
if confere_sessoes ok; then
  ok "as duas concluíram; a segunda esperou ($ESPERA_B): o advisory lock 150001 serializa toda aprovação, por desenho"
  confere "bateria 30000 → 33000 e combustível 40000 → 44000" \
    "$(vigente bateria base) = 33000 AND $(vigente combustivel base) = 44000"
else
  falhou "4: $MOTIVO"
fi

echo "== Cenário 5: duas concessões simultâneas da mesma permissão ao mesmo operador"
corrida safetycar_central "SELECT conceder_permissao('$U3', '$OP', 'aprovar_reajuste_taxa', '[TESTE] conc 5: A');" \
        safetycar_central "SELECT conceder_permissao('$U1', '$OP', 'aprovar_reajuste_taxa', '[TESTE] conc 5: B');"
if confere_sessoes SC018; then
  ok "U3 concedeu; U1 esperou ($ESPERA_B) e terminou em SC018"
  confere "uma única concessão vigente, concedida por U3" \
    "(SELECT count(*) FROM vw_permissao_vigente WHERE operador_id = '$OP' AND permissao_codigo = 'aprovar_reajuste_taxa') = 1
     AND (SELECT concedida_por = '$U3' FROM vw_permissao_vigente WHERE operador_id = '$OP' AND permissao_codigo = 'aprovar_reajuste_taxa')"
else
  falhou "5: $MOTIVO"
fi

echo "== Cenário 6: regra \"a definir\" entra no escopo enquanto a aprovação espera"
corrida safetycar_migrator "SELECT pg_advisory_xact_lock(150001);
INSERT INTO regra_taxa (tipo_parceiro_codigo, servico_codigo, uf, componente, unidade, valor, situacao, observacao)
VALUES ('chaveiro', 'mecanica_movel', 'SP', 'base', 'centavos', 0, 'a_definir', '[TESTE] conc 6: entrou durante a aprovação');" \
        safetycar_central "$(aprova "$P1" "$L6")"
if confere_sessoes SC013; then
  ok "a aprovação esperou ($ESPERA_B), enxergou a regra nova e terminou em SC013"
  confere "nenhuma regra alterada: sem versão nova, a nacional segue aberta com 50000 e o lote continua solicitado" \
    "NOT EXISTS (SELECT 1 FROM regra_taxa WHERE reajuste_id = '$L6')
     AND (SELECT fim_vigencia IS NULL AND valor = 50000 FROM regra_taxa
           WHERE tipo_parceiro_codigo = 'chaveiro' AND servico_codigo = 'mecanica_movel' AND uf IS NULL)
     AND (SELECT situacao = 'solicitado' FROM vw_reajuste_taxa WHERE id = '$L6')"
else
  falhou "6: $MOTIVO"
fi

# ---------------------------------------------------------------------------------------------
# 0016: último titular de conceder_permissao. Aqui os titulares são U3 (inicial, 1b) e U1.
EFETIVOS_CONCEDER="SELECT count(*) FROM vw_permissao_vigente WHERE permissao_codigo = 'conceder_permissao' AND efetiva"

echo "== Cenário 7a: os dois últimos titulares revogam a própria conceder_permissao ao mesmo tempo"
corrida safetycar_central "SELECT revogar_permissao('$U3', '$U3', 'conceder_permissao', '[TESTE] conc 7a: A');" \
        safetycar_central "SELECT revogar_permissao('$U1', '$U1', 'conceder_permissao', '[TESTE] conc 7a: B');"
if confere_sessoes SC023; then
  ok "U3 revogou; U1 esperou ($ESPERA_B) e terminou em SC023, não em 40P01"
  confere "sobra um titular efetivo, U1" \
    "($EFETIVOS_CONCEDER) = 1 AND EXISTS (SELECT 1 FROM vw_permissao_vigente WHERE permissao_codigo = 'conceder_permissao' AND operador_id = '$U1' AND efetiva)"
else
  falhou "7a: $MOTIVO"
fi

echo "== Cenário 7b: desativação de um titular e autorrevogação do outro, ao mesmo tempo"
sql >/dev/null -c "SELECT conceder_permissao('$U1', '$OP', 'conceder_permissao', '[TESTE] conc 7b: segundo titular')"
corrida safetycar_central "SELECT definir_operador_ativo('$U1', '$OP', false, '[TESTE] conc 7b: A');" \
        safetycar_central "SELECT revogar_permissao('$U1', '$U1', 'conceder_permissao', '[TESTE] conc 7b: B');"
if confere_sessoes SC023; then
  ok "OP foi desativado; a revogação de U1 esperou ($ESPERA_B) e terminou em SC023"
  confere "U1 segue como único titular efetivo e OP está inativo" \
    "($EFETIVOS_CONCEDER) = 1 AND (SELECT NOT ativo FROM operador_central WHERE usuario_id = '$OP')
     AND EXISTS (SELECT 1 FROM vw_permissao_vigente WHERE permissao_codigo = 'conceder_permissao' AND operador_id = '$U1' AND efetiva)"
else
  falhou "7b: $MOTIVO"
fi

# ---------------------------------------------------------------------------------------------
# 0017: definição da primeira tarifa em lote (S1 e S2 já têm solicitar_reajuste_taxa).
J8='[{"tipo_parceiro":"guincho","servico":"guincho_pesado","nacional":true,"componente":"base","valor":30000}]'
J9='[{"tipo_parceiro":"guincho","servico":"guincho_pesado","nacional":true,"componente":"minimo","valor":8000}]'

echo "== Cenário 8: duas aprovações simultâneas do MESMO lote de definição"
L8="$(sql -c "SELECT solicitar_definicao_taxa('$S1', '$J8'::jsonb, '[TESTE] conc 8: lote')")"
aprova_def() { echo "SELECT aprovar_definicao_taxa('$1', '$2', '[TESTE] conc: aprovação');"; }
corrida safetycar_central "$(aprova_def "$P1" "$L8")" safetycar_central "$(aprova_def "$P2" "$L8")"
if confere_sessoes SC020; then
  ok "P1 aprovou; P2 esperou ($ESPERA_B) e terminou em SC020"
  confere "uma única decisão e uma única regra definida: 30000, contígua à regra a definir que encerrou" \
    "(SELECT count(*) FROM definicao_taxa_decisao WHERE definicao_id = '$L8') = 1
     AND (SELECT count(*) FROM regra_taxa WHERE definicao_id = '$L8') = 1
     AND (SELECT valor FROM regra_taxa_vigente('guincho', 'guincho_pesado', NULL, 'base')) = 30000
     AND (SELECT o.fim_vigencia = n.inicio_vigencia AND o.situacao = 'a_definir'
            FROM regra_taxa n JOIN regra_taxa o ON o.id = n.regra_origem_id WHERE n.definicao_id = '$L8')"
else
  falhou "8: $MOTIVO"
fi

echo "== Cenário 9: duas solicitações simultâneas de definição no mesmo escopo"
corrida safetycar_central "SELECT solicitar_definicao_taxa('$S1', '$J9'::jsonb, '[TESTE] conc 9: A');" \
        safetycar_central "SELECT solicitar_definicao_taxa('$S2', '$J9'::jsonb, '[TESTE] conc 9: B');"
if confere_sessoes SC024; then
  ok "A solicitou; B esperou ($ESPERA_B) e terminou em SC024"
  confere "um único lote cobre o mínimo do guincho pesado, o de S1" \
    "(SELECT count(*) FROM definicao_taxa_item WHERE servico_codigo = 'guincho_pesado' AND componente = 'minimo') = 1
     AND (SELECT d.solicitado_por = '$S1' FROM definicao_taxa d JOIN definicao_taxa_item i ON i.definicao_id = d.id
           WHERE i.servico_codigo = 'guincho_pesado' AND i.componente = 'minimo')"
else
  falhou "9: $MOTIVO"
fi

# ---------------------------------------------------------------------------------------------
# 0018: parâmetros. S1 e S2 pedem; P1 e P2 decidem (todos com administrar_parametros).
sql >/dev/null <<SQL
SELECT conceder_permissao('$U1', o::uuid, 'administrar_parametros', '[TESTE] conc: parâmetros')
  FROM unnest(ARRAY['$S1','$S2','$P1','$P2']) o;
SQL
LIMITE="(SELECT valor FROM vw_parametro_vigente WHERE chave = 'limite_variacao_reajuste')"

echo "== Cenário 10: duas aprovações simultâneas do MESMO pedido de parâmetro sensível"
X10="$(sql -c "SELECT solicitar_alteracao_parametro('$S1', 'limite_variacao_reajuste', 25, '[TESTE] conc 10: pedido')")"
aprova_par() { echo "SELECT aprovar_alteracao_parametro('$1', '$2', '[TESTE] conc: aprovação');"; }
corrida safetycar_central "$(aprova_par "$P1" "$X10")" safetycar_central "$(aprova_par "$P2" "$X10")"
if confere_sessoes SC020; then
  ok "P1 aprovou; P2 esperou ($ESPERA_B) e terminou em SC020"
  confere "uma única decisão, um único valor novo (25) e um só valor em aberto, contíguo ao anterior" \
    "(SELECT count(*) FROM parametro_alteracao_decisao WHERE alteracao_id = '$X10') = 1
     AND (SELECT count(*) FROM parametro_valor WHERE alteracao_id = '$X10') = 1
     AND $LIMITE = 25
     AND (SELECT count(*) FROM parametro_valor WHERE parametro_chave = 'limite_variacao_reajuste' AND fim_vigencia IS NULL) = 1
     AND (SELECT o.fim_vigencia = n.inicio_vigencia FROM parametro_valor n
            JOIN parametro_valor o ON o.parametro_chave = n.parametro_chave AND o.fim_vigencia = n.inicio_vigencia
           WHERE n.alteracao_id = '$X10')"
else
  falhou "10: $MOTIVO"
fi

echo "== Cenário 11: dois pedidos simultâneos para o mesmo parâmetro sensível"
corrida safetycar_central "SELECT solicitar_alteracao_parametro('$S1', 'limite_variacao_reajuste', 30, '[TESTE] conc 11: A');" \
        safetycar_central "SELECT solicitar_alteracao_parametro('$S2', 'limite_variacao_reajuste', 35, '[TESTE] conc 11: B');"
if confere_sessoes SC024; then
  ok "A pediu; B esperou ($ESPERA_B) e terminou em SC024"
  confere "um único pedido em aberto, o de S1, e o limite segue 25" \
    "(SELECT count(*) FROM vw_parametro_alteracao WHERE parametro_chave = 'limite_variacao_reajuste' AND situacao = 'solicitado') = 1
     AND (SELECT solicitado_por = '$S1' FROM vw_parametro_alteracao WHERE parametro_chave = 'limite_variacao_reajuste' AND situacao = 'solicitado')
     AND $LIMITE = 25"
else
  falhou "11: $MOTIVO"
fi

# ---------------------------------------------------------------------------------------------
# 0019: um lote de reajuste em aberto por escopo.
echo "== Cenário 12: duas solicitações simultâneas de reajuste com escopo sobreposto"
corrida safetycar_central "$(sol_sql "$S1" 5 pneu minimo)" safetycar_central "$(sol_sql "$S2" 7 pneu minimo)"
if confere_sessoes SC024; then
  ok "A solicitou; B esperou ($ESPERA_B) e terminou em SC024"
  confere "um único lote em aberto para o mínimo do pneu, o de S1" \
    "(SELECT count(*) FROM vw_reajuste_taxa WHERE situacao = 'solicitado' AND servicos = '{pneu}' AND componentes = '{minimo}') = 1
     AND (SELECT solicitado_por = '$S1' FROM vw_reajuste_taxa WHERE situacao = 'solicitado' AND servicos = '{pneu}' AND componentes = '{minimo}')"
else
  falhou "12: $MOTIVO"
fi

# ---------------------------------------------------------------------------------------------
echo "== Checagem final de sobreposição"
confere "nenhuma vigência sobreposta em regra_taxa" \
  "NOT EXISTS (SELECT 1 FROM regra_taxa a JOIN regra_taxa b ON a.id < b.id
                AND a.tipo_parceiro_codigo = b.tipo_parceiro_codigo AND a.servico_codigo = b.servico_codigo
                AND coalesce(a.uf::text, '*') = coalesce(b.uf::text, '*') AND a.componente = b.componente
                AND tstzrange(a.inicio_vigencia, a.fim_vigencia, '[)') && tstzrange(b.inicio_vigencia, b.fim_vigencia, '[)'))"
confere "nenhuma vigência sobreposta em politica_garantia" \
  "NOT EXISTS (SELECT 1 FROM politica_garantia a JOIN politica_garantia b ON a.id < b.id
                AND a.servico_codigo = b.servico_codigo AND a.nivel_verificacao = b.nivel_verificacao
                AND a.modalidade = b.modalidade
                AND tstzrange(a.inicio_vigencia, a.fim_vigencia, '[)') && tstzrange(b.inicio_vigencia, b.fim_vigencia, '[)'))"
confere "nenhuma vigência sobreposta em parametro_valor" \
  "NOT EXISTS (SELECT 1 FROM parametro_valor a JOIN parametro_valor b ON a.id < b.id
                AND a.parametro_chave = b.parametro_chave
                AND tstzrange(a.inicio_vigencia, a.fim_vigencia, '[)') && tstzrange(b.inicio_vigencia, b.fim_vigencia, '[)'))"

echo
if (( FALHAS > 0 )); then
  echo "== $FALHAS de $TOTAL verificações FALHARAM."
  exit 1
fi
echo "== Todas as $TOTAL verificações de concorrência passaram."
