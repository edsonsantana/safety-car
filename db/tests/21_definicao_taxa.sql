-- 21 — Regiões e definição da primeira tarifa em lote (0017), como safetycar_migrator.
-- Usuários FICTÍCIOS: A administrador; S solicitante; P aprovador; Q solicita e aprova;
-- X operador sem permissão; T tomador.

INSERT INTO usuario (id, keycloak_sub, email, perfil, status) VALUES
  ('00000000-0000-4000-8000-0000000d1a01', gen_random_uuid(), 'def-a@exemplo.invalid', 'central', 'ativo'),
  ('00000000-0000-4000-8000-0000000d1a02', gen_random_uuid(), 'def-s@exemplo.invalid', 'central', 'ativo'),
  ('00000000-0000-4000-8000-0000000d1a03', gen_random_uuid(), 'def-p@exemplo.invalid', 'central', 'ativo'),
  ('00000000-0000-4000-8000-0000000d1a04', gen_random_uuid(), 'def-q@exemplo.invalid', 'central', 'ativo'),
  ('00000000-0000-4000-8000-0000000d1a05', gen_random_uuid(), 'def-x@exemplo.invalid', 'central', 'ativo'),
  ('00000000-0000-4000-8000-0000000d1a09', gen_random_uuid(), 'def-t@exemplo.invalid', 'tomador', 'ativo');

CREATE FUNCTION pg_temp.u(p text) RETURNS uuid LANGUAGE sql IMMUTABLE AS $f$
  SELECT ('00000000-0000-4000-8000-0000000d1a0' ||
          CASE p WHEN 'A' THEN '1' WHEN 'S' THEN '2' WHEN 'P' THEN '3' WHEN 'Q' THEN '4' WHEN 'X' THEN '5' ELSE '9' END)::uuid
$f$;

CREATE TEMP TABLE v (k text PRIMARY KEY, id uuid, t timestamptz);
CREATE FUNCTION pg_temp.id(p text) RETURNS uuid LANGUAGE sql STABLE AS $f$ SELECT id FROM v WHERE k = p $f$;
CREATE FUNCTION pg_temp.t(p text) RETURNS timestamptz LANGUAGE sql STABLE AS $f$ SELECT t FROM v WHERE k = p $f$;

-- Simulação (como P, que pode simular) e solicitação.
CREATE FUNCTION pg_temp.sim(p_itens text) RETURNS bigint LANGUAGE sql AS $f$
  SELECT count(*) FROM simular_definicao_taxa('00000000-0000-4000-8000-0000000d1a03'::uuid, p_itens::jsonb)
$f$;
CREATE FUNCTION pg_temp.sol(p_ator text, p_itens text) RETURNS uuid LANGUAGE sql AS $f$
  SELECT solicitar_definicao_taxa(pg_temp.u(p_ator), p_itens::jsonb, '[TESTE] definição')
$f$;
-- Valor da regra vigente agora (UF ou nacional), sem passar por regra_taxa_vigente.
CREATE FUNCTION pg_temp.regra(p_tipo text, p_servico text, p_uf text, p_comp text) RETURNS regra_taxa
LANGUAGE sql STABLE AS $f$
  SELECT r.* FROM regra_taxa r
   WHERE r.tipo_parceiro_codigo = p_tipo AND r.servico_codigo = p_servico AND r.componente = p_comp
     AND r.uf::text IS NOT DISTINCT FROM p_uf
     AND tstzrange(r.inicio_vigencia, r.fim_vigencia, '[)') @> clock_timestamp()
$f$;

-- ---------- Regiões ----------
SELECT pg_temp.confere(
  (SELECT array_agg(codigo ORDER BY codigo) FROM regiao) = '{centro_oeste,nordeste,norte,sudeste,sul}',
  'cinco regiões');
SELECT pg_temp.confere(
  (SELECT count(*) = 27 AND count(DISTINCT uf) = 27 FROM regiao_uf),
  '27 UFs, uma vez cada');
SELECT pg_temp.confere(
  (SELECT string_agg(regiao_codigo || ':' || n, ',' ORDER BY regiao_codigo)
     FROM (SELECT regiao_codigo, count(*) n FROM regiao_uf GROUP BY regiao_codigo) x)
   = 'centro_oeste:4,nordeste:9,norte:7,sudeste:4,sul:3',
  'UFs por região: Norte 7, Nordeste 9, Centro-Oeste 4, Sudeste 4, Sul 3');
SELECT pg_temp.confere(
  ufs_da_regiao('sul') = '{PR,RS,SC}' AND ufs_da_regiao('sudeste') = '{ES,MG,RJ,SP}'
  AND (SELECT regiao_codigo = 'centro_oeste' FROM regiao_uf WHERE uf = 'DF'),
  'expansão da região nas UFs');
SELECT pg_temp.espera_erro($$SELECT ufs_da_regiao('leste')$$, '22023', 'região inexistente');
SELECT pg_temp.espera_erro($$TRUNCATE regiao_uf$$, '0A000', 'TRUNCATE em regiao_uf é recusado (referenciada por FK)');
SELECT pg_temp.espera_erro($$TRUNCATE regiao, regiao_uf CASCADE$$, 'SC010', 'TRUNCATE em cascata é bloqueado pelo trigger');
SELECT pg_temp.confere(
  (SELECT count(*) = 5 FROM auditoria WHERE entidade = 'regiao' AND acao = 'parametrizacao_insert')
  AND (SELECT count(*) = 27 FROM auditoria WHERE entidade = 'regiao_uf' AND acao = 'parametrizacao_insert'),
  'carga das regiões e UFs na auditoria');

-- ---------- Equipe e carga ----------
SELECT conceder_permissao_inicial(pg_temp.u('A'), '[TESTE] administrador');
SELECT cadastrar_operador(pg_temp.u('A'), pg_temp.u(o), '[TESTE] equipe') FROM unnest(ARRAY['S','P','Q','X']) o;
SELECT conceder_permissao(pg_temp.u('A'), pg_temp.u('S'), 'solicitar_reajuste_taxa', '[TESTE] solicitante');
SELECT conceder_permissao(pg_temp.u('A'), pg_temp.u('P'), 'aprovar_reajuste_taxa', '[TESTE] aprovador');
SELECT conceder_permissao(pg_temp.u('A'), pg_temp.u('Q'), 'solicitar_reajuste_taxa', '[TESTE] solicita e aprova');
SELECT conceder_permissao(pg_temp.u('A'), pg_temp.u('Q'), 'aprovar_reajuste_taxa', '[TESTE] solicita e aprova');

SELECT pg_temp.confere(
  (SELECT count(*) = 42 FROM regra_taxa WHERE situacao = 'a_definir' AND fim_vigencia IS NULL AND uf IS NULL),
  'carga: 42 regras nacionais a definir');

-- ---------- Permissões ----------
SELECT pg_temp.espera_erro($$SELECT pg_temp.sol('X', '[{"tipo_parceiro":"guincho","servico":"guincho_leve","nacional":true,"componente":"base","valor":1}]')$$,
  'SC016', 'sem solicitar_reajuste_taxa não solicita');
SELECT pg_temp.espera_erro($$SELECT pg_temp.sol('P', '[{"tipo_parceiro":"guincho","servico":"guincho_leve","nacional":true,"componente":"base","valor":1}]')$$,
  'SC016', 'o aprovador sem solicitar_reajuste_taxa não solicita');
SELECT pg_temp.espera_erro($$SELECT count(*) FROM simular_definicao_taxa(pg_temp.u('X'),
  '[{"tipo_parceiro":"guincho","servico":"guincho_leve","nacional":true,"componente":"base","valor":1}]'::jsonb)$$,
  'SC016', 'sem solicitar nem aprovar, não simula');
SELECT pg_temp.confere(
  (SELECT count(*) = 1 FROM simular_definicao_taxa(pg_temp.u('S'),
     '[{"tipo_parceiro":"guincho","servico":"guincho_leve","nacional":true,"componente":"base","valor":1}]'::jsonb))
  AND pg_temp.sim('[{"tipo_parceiro":"guincho","servico":"guincho_leve","nacional":true,"componente":"base","valor":1}]') = 1,
  'quem solicita e quem aprova simulam');

-- ---------- Validação dos itens (22023) ----------
SELECT pg_temp.espera_erro($$SELECT pg_temp.sim('[]')$$, '22023', 'lista vazia');
SELECT pg_temp.espera_erro($$SELECT pg_temp.sim('{}')$$, '22023', 'itens que não são lista');
SELECT pg_temp.espera_erro($$SELECT pg_temp.sim('[1]')$$, '22023', 'item que não é objeto');
SELECT pg_temp.espera_erro($$SELECT pg_temp.sim('[{"tipo_parceiro":"guincho","servico":"guincho_leve","nacional":true,"componente":"base","valor":1,"preco":2}]')$$,
  '22023', 'chave desconhecida');
SELECT pg_temp.espera_erro($$SELECT pg_temp.sim('[{"tipo_parceiro":"guincho","servico":"guincho_leve","nacional":true,"uf":"SP","componente":"base","valor":1}]')$$,
  '22023', 'dois alvos (nacional e uf)');
SELECT pg_temp.espera_erro($$SELECT pg_temp.sim('[{"tipo_parceiro":"guincho","servico":"guincho_leve","componente":"base","valor":1}]')$$,
  '22023', 'nenhum alvo: o nacional nunca é suposto');
SELECT pg_temp.espera_erro($$SELECT pg_temp.sim('[{"tipo_parceiro":"guincho","servico":"guincho_leve","nacional":false,"componente":"base","valor":1}]')$$,
  '22023', 'nacional só aceita true');
SELECT pg_temp.espera_erro($$SELECT pg_temp.sim('[{"tipo_parceiro":"borracharia","servico":"pneu","nacional":true,"componente":"base","valor":1}]')$$,
  '22023', 'tipo de parceiro inexistente');
SELECT pg_temp.espera_erro($$SELECT pg_temp.sim('[{"tipo_parceiro":"guincho","servico":"reboque","nacional":true,"componente":"base","valor":1}]')$$,
  '22023', 'serviço inexistente');
SELECT pg_temp.espera_erro($$SELECT pg_temp.sim('[{"tipo_parceiro":"chaveiro","servico":"guincho_leve","nacional":true,"componente":"base","valor":1}]')$$,
  '22023', 'combinação tipo × serviço fora da carga');
SELECT pg_temp.espera_erro($$SELECT pg_temp.sim('[{"tipo_parceiro":"guincho","servico":"guincho_leve","nacional":true,"componente":"taxa","valor":1}]')$$,
  '22023', 'componente inválido');
SELECT pg_temp.espera_erro($$SELECT pg_temp.sim('[{"tipo_parceiro":"guincho","servico":"guincho_leve","nacional":true,"componente":"cancelamento","valor":1}]')$$,
  '22023', 'cancelamento sem unidade');
SELECT pg_temp.espera_erro($$SELECT pg_temp.sim('[{"tipo_parceiro":"guincho","servico":"guincho_leve","nacional":true,"componente":"base","unidade":"pontos_base","valor":1}]')$$,
  '22023', 'unidade incompatível com o componente');
SELECT pg_temp.espera_erro($$SELECT pg_temp.sim('[{"tipo_parceiro":"guincho","servico":"guincho_leve","nacional":true,"componente":"base","valor":-1}]')$$,
  '22023', 'valor negativo');
SELECT pg_temp.espera_erro($$SELECT pg_temp.sim('[{"tipo_parceiro":"guincho","servico":"guincho_leve","nacional":true,"componente":"base","valor":10.5}]')$$,
  '22023', 'valor fracionário (é inteiro em centavos)');
SELECT pg_temp.espera_erro($$SELECT pg_temp.sim('[{"tipo_parceiro":"guincho","servico":"guincho_leve","nacional":true,"componente":"base","valor":"100"}]')$$,
  '22023', 'valor em texto');
SELECT pg_temp.espera_erro($$SELECT pg_temp.sim('[{"tipo_parceiro":"guincho","servico":"guincho_leve","nacional":true,"componente":"base"}]')$$,
  '22023', 'valor ausente');
SELECT pg_temp.espera_erro($$SELECT pg_temp.sim('[{"tipo_parceiro":"guincho","servico":"guincho_leve","nacional":true,"componente":"comissao_plataforma","valor":10001}]')$$,
  '22023', 'pontos-base acima de 10000');
SELECT pg_temp.espera_erro($$SELECT pg_temp.sim('[{"tipo_parceiro":"guincho","servico":"guincho_leve","uf":"XX","componente":"base","valor":1}]')$$,
  '22023', 'UF inválida');
SELECT pg_temp.espera_erro($$SELECT pg_temp.sim('[{"tipo_parceiro":"guincho","servico":"guincho_leve","regiao":"leste","componente":"base","valor":1}]')$$,
  '22023', 'região inexistente');
SELECT pg_temp.confere(
  (SELECT count(*) = 2 FROM simular_definicao_taxa(pg_temp.u('P'),
     '[{"tipo_parceiro":"guincho","servico":"guincho_leve","regiao":"nordeste","componente":"base","valor":1},
       {"tipo_parceiro":"guincho","servico":"guincho_leve","uf":"BA","componente":"base","valor":2}]'::jsonb)
    WHERE uf = 'BA' AND problema = 'duplicado'),
  'simulação marca "duplicado" quando a região e a UF caem no mesmo escopo');
SELECT pg_temp.espera_erro($$SELECT pg_temp.sol('S',
  '[{"tipo_parceiro":"guincho","servico":"guincho_leve","regiao":"nordeste","componente":"base","valor":1},
    {"tipo_parceiro":"guincho","servico":"guincho_leve","uf":"BA","componente":"base","valor":2}]')$$,
  '22023', 'a solicitação recusa item duplicado');

-- ---------- Lote L1: 4 definições nacionais + região Sudeste (4 UFs criadas) ----------
CREATE FUNCTION pg_temp.l1() RETURNS text LANGUAGE sql IMMUTABLE AS $f$ SELECT
 '[{"tipo_parceiro":"guincho","servico":"guincho_leve","nacional":true,"componente":"base","valor":15000},
   {"tipo_parceiro":"guincho","servico":"guincho_leve","nacional":true,"componente":"por_km","valor":450},
   {"tipo_parceiro":"guincho","servico":"guincho_leve","nacional":true,"componente":"cancelamento","unidade":"pontos_base","valor":1000},
   {"tipo_parceiro":"guincho","servico":"guincho_leve","nacional":true,"componente":"comissao_plataforma","valor":1500},
   {"tipo_parceiro":"guincho","servico":"guincho_leve","regiao":"sudeste","componente":"base","valor":18000}]'
$f$;
SELECT pg_temp.confere(
  (SELECT count(*) = 8
      AND count(*) FILTER (WHERE acao = 'definir' AND situacao_atual = 'a_definir' AND uf IS NULL) = 4
      AND count(*) FILTER (WHERE acao = 'criar' AND regiao_codigo = 'sudeste' AND regra_atual_id IS NULL) = 4
      AND bool_and(problema IS NULL)
     FROM simular_definicao_taxa(pg_temp.u('S'), pg_temp.l1()::jsonb)),
  'simulação de L1: 4 regras a definir viram definidas e 4 regras de UF do Sudeste são criadas');

INSERT INTO v (k, id) SELECT 'L1', pg_temp.sol('S', pg_temp.l1());
SELECT pg_temp.confere(
  (SELECT situacao = 'solicitado' AND itens = 8 AND solicitado_por = pg_temp.u('S') FROM vw_definicao_taxa WHERE id = pg_temp.id('L1'))
  AND (SELECT count(*) = 4 FROM definicao_taxa_item WHERE definicao_id = pg_temp.id('L1') AND regiao_codigo = 'sudeste'),
  'L1 solicitado com 8 itens (a região virou 4 UFs, com a origem registrada)');
SELECT pg_temp.espera_erro($$SELECT regra_taxa_vigente('guincho', 'guincho_leve', 'SP', 'base')$$,
  'SC013', 'solicitar não altera regra nenhuma: SP continua a definir');

-- ---------- Lote em aberto no mesmo escopo (SC024) ----------
SELECT pg_temp.espera_erro($$SELECT pg_temp.sol('S', '[{"tipo_parceiro":"guincho","servico":"guincho_leve","nacional":true,"componente":"base","valor":16000}]')$$,
  'SC024', 'outro lote no mesmo escopo, com L1 em aberto, é recusado');
SELECT pg_temp.espera_erro($$SELECT pg_temp.sol('S', '[{"tipo_parceiro":"guincho","servico":"guincho_leve","uf":"RJ","componente":"base","valor":16000}]')$$,
  'SC024', 'também quando a sobreposição vem da região expandida (RJ)');
INSERT INTO v (k, id) SELECT 'L2', pg_temp.sol('S', '[{"tipo_parceiro":"mecanica","servico":"bateria","nacional":true,"componente":"base","valor":9000}]');
INSERT INTO v (k, id) SELECT 'L3', pg_temp.sol('Q', '[{"tipo_parceiro":"mecanica","servico":"pneu","nacional":true,"componente":"base","valor":7000}]');
SELECT pg_temp.confere(pg_temp.id('L2') IS NOT NULL AND pg_temp.id('L3') IS NOT NULL,
  'lotes de escopos disjuntos convivem (L2 de S, L3 de Q)');

-- ---------- Quem decide ----------
SELECT pg_temp.espera_erro($$SELECT aprovar_definicao_taxa(pg_temp.u('X'), pg_temp.id('L1'), '[TESTE]')$$,
  'SC016', 'sem aprovar_reajuste_taxa não aprova');
SELECT pg_temp.espera_erro($$SELECT aprovar_definicao_taxa(pg_temp.u('S'), pg_temp.id('L1'), '[TESTE]')$$,
  'SC016', 'o solicitante sem a permissão não aprova');
SELECT pg_temp.espera_erro($$SELECT aprovar_definicao_taxa(pg_temp.u('Q'), pg_temp.id('L3'), '[TESTE]')$$,
  'SC017', 'quem pediu não aprova o próprio lote, mesmo com a permissão');
SELECT pg_temp.espera_erro($$SELECT rejeitar_definicao_taxa(pg_temp.u('Q'), pg_temp.id('L3'), '[TESTE]')$$,
  'SC017', 'quem pediu também não rejeita o próprio lote (cancela)');
SELECT pg_temp.espera_erro($$SELECT aprovar_definicao_taxa(pg_temp.u('P'), pg_temp.id('L1'), '  ')$$,
  '22023', 'aprovação sem motivo');
SELECT pg_temp.espera_erro($$SELECT aprovar_definicao_taxa(pg_temp.u('P'), gen_random_uuid(), '[TESTE]')$$,
  '22023', 'lote inexistente');
UPDATE usuario SET status = 'suspenso' WHERE id = pg_temp.u('P');
SELECT pg_temp.espera_erro($$SELECT aprovar_definicao_taxa(pg_temp.u('P'), pg_temp.id('L1'), '[TESTE]')$$,
  'SC016', 'aprovador suspenso não aprova');
UPDATE usuario SET status = 'ativo' WHERE id = pg_temp.u('P');

-- ---------- Aprovação de L1 ----------
-- O arquivo roda numa só transação: now() é o início dela, e as regras novas começam em
-- clock_timestamp(). Por isso as consultas abaixo passam o instante explícito.
SELECT pg_temp.confere(aprovar_definicao_taxa(pg_temp.u('P'), pg_temp.id('L1'), '[TESTE] valores do alinhamento') = 8,
  'P aprova L1: 8 regras');
INSERT INTO v (k, t) SELECT 'inicio_l1', inicio_efetivo FROM definicao_taxa_decisao WHERE definicao_id = pg_temp.id('L1');

SELECT pg_temp.confere(
  (regra_taxa_vigente('guincho', 'guincho_leve', 'SP', 'base', clock_timestamp())).valor = 18000
  AND (regra_taxa_vigente('guincho', 'guincho_leve', 'MG', 'base', clock_timestamp())).valor = 18000
  AND (regra_taxa_vigente('guincho', 'guincho_leve', 'BA', 'base', clock_timestamp())).valor = 15000,
  'SP e MG (Sudeste) com 18000; BA segue a nacional, 15000');
SELECT pg_temp.confere(
  (SELECT valor = 450 AND base_distancia = 'linha_reta' FROM pg_temp.regra('guincho', 'guincho_leve', NULL, 'por_km'))
  AND (SELECT valor = 1000 AND unidade = 'pontos_base' FROM pg_temp.regra('guincho', 'guincho_leve', NULL, 'cancelamento'))
  AND (SELECT valor = 1500 FROM pg_temp.regra('guincho', 'guincho_leve', NULL, 'comissao_plataforma')),
  'por km com linha_reta; cancelamento em pontos-base; comissão');
SELECT pg_temp.confere(
  (SELECT count(*) = 8 AND bool_and(situacao = 'definido' AND inicio_vigencia = pg_temp.t('inicio_l1') AND fim_vigencia IS NULL)
     FROM regra_taxa WHERE definicao_id = pg_temp.id('L1')),
  '8 regras definidas pelo lote, todas a partir do mesmo instante');
SELECT pg_temp.confere(
  (SELECT count(*) = 4 FROM regra_taxa n JOIN regra_taxa o ON o.id = n.regra_origem_id
    WHERE n.definicao_id = pg_temp.id('L1') AND o.situacao = 'a_definir'
      AND o.fim_vigencia = n.inicio_vigencia AND o.uf IS NULL)
  AND (SELECT count(*) = 4 FROM regra_taxa WHERE definicao_id = pg_temp.id('L1') AND uf IS NOT NULL AND regra_origem_id IS NULL),
  'as 4 nacionais substituem a regra a definir, contíguas; as 4 de UF são novas, sem origem');
SELECT pg_temp.espera_erro($$SELECT regra_taxa_vigente('guincho', 'guincho_leve', 'BA', 'base', pg_temp.t('inicio_l1') - interval '1 microsecond')$$,
  'SC013', 'antes do início, a regra continua a definir (nada retroage)');
SELECT pg_temp.confere(
  (SELECT situacao = 'aprovado' AND decidido_por = pg_temp.u('P') AND regras_afetadas = 8
     FROM vw_definicao_taxa WHERE id = pg_temp.id('L1')),
  'decisão de L1: aprovado por P, 8 regras');
SELECT pg_temp.confere(
  (SELECT count(*) = 38 FROM regra_taxa WHERE situacao = 'a_definir' AND fim_vigencia IS NULL),
  'restam 38 regras a definir');
SELECT pg_temp.espera_erro($$SELECT aprovar_definicao_taxa(pg_temp.u('P'), pg_temp.id('L1'), '[TESTE]')$$,
  'SC020', 'lote aprovado não é aprovado de novo');
SELECT pg_temp.espera_erro($$SELECT rejeitar_definicao_taxa(pg_temp.u('P'), pg_temp.id('L1'), '[TESTE]')$$,
  'SC020', 'lote aprovado não é rejeitado');
SELECT pg_temp.espera_erro($$SELECT cancelar_definicao_taxa(pg_temp.u('S'), pg_temp.id('L1'), '[TESTE]')$$,
  'SC020', 'lote aprovado não é cancelado');

-- ---------- Regra já definida (SC028) e UF que passa a prevalecer ----------
SELECT pg_temp.espera_erro($$SELECT pg_temp.sol('S', '[{"tipo_parceiro":"guincho","servico":"guincho_leve","nacional":true,"componente":"base","valor":20000}]')$$,
  'SC028', 'regra nacional já definida: o caminho é o reajuste');
SELECT pg_temp.espera_erro($$SELECT pg_temp.sol('S', '[{"tipo_parceiro":"guincho","servico":"guincho_leve","uf":"SP","componente":"base","valor":20000}]')$$,
  'SC028', 'regra de UF já definida: o caminho é o reajuste');
INSERT INTO v (k, id) SELECT 'L4', pg_temp.sol('S', '[{"tipo_parceiro":"guincho","servico":"guincho_leve","uf":"BA","componente":"base","valor":16000}]');
SELECT pg_temp.confere(aprovar_definicao_taxa(pg_temp.u('P'), pg_temp.id('L4'), '[TESTE] Bahia') = 1,
  'L4 cria a regra da BA');
SELECT pg_temp.confere(
  (regra_taxa_vigente('guincho', 'guincho_leve', 'BA', 'base', clock_timestamp())).valor = 16000
  AND (regra_taxa_vigente('guincho', 'guincho_leve', 'MA', 'base', clock_timestamp())).valor = 15000,
  'BA passa a 16000; MA continua na nacional');

-- ---------- Rejeição e cancelamento ----------
SELECT pg_temp.aceita($$SELECT rejeitar_definicao_taxa(pg_temp.u('P'), pg_temp.id('L2'), '[TESTE] valor a revisar')$$,
  'P rejeita L2');
SELECT pg_temp.espera_erro($$SELECT regra_taxa_vigente('mecanica', 'bateria', 'SP', 'base')$$,
  'SC013', 'rejeitar não altera nada: bateria continua a definir');
INSERT INTO v (k, id) SELECT 'L5', pg_temp.sol('S', '[{"tipo_parceiro":"mecanica","servico":"bateria","nacional":true,"componente":"base","valor":9500}]');
SELECT pg_temp.confere(pg_temp.id('L5') IS NOT NULL, 'depois da rejeição, o mesmo escopo pode ser pedido de novo');
SELECT pg_temp.espera_erro($$SELECT cancelar_definicao_taxa(pg_temp.u('X'), pg_temp.id('L5'), '[TESTE]')$$,
  'SC016', 'quem não é o solicitante nem aprovador não cancela');
SELECT pg_temp.aceita($$SELECT cancelar_definicao_taxa(pg_temp.u('S'), pg_temp.id('L5'), '[TESTE] desisti')$$,
  'o solicitante cancela o próprio lote');
SELECT pg_temp.confere(
  (SELECT situacao = 'rejeitado' FROM vw_definicao_taxa WHERE id = pg_temp.id('L2'))
  AND (SELECT situacao = 'cancelado' AND decidido_por = pg_temp.u('S') FROM vw_definicao_taxa WHERE id = pg_temp.id('L5')),
  'situações rejeitado e cancelado');

-- ---------- Regra futura agendada no escopo (SC021) ----------
INSERT INTO regra_taxa (tipo_parceiro_codigo, servico_codigo, uf, componente, unidade, valor, situacao, observacao, inicio_vigencia)
VALUES ('mecanica', 'combustivel', 'RJ', 'base', 'centavos', 3000, 'definido', '[TESTE] futura', now() + interval '1 day');
SELECT pg_temp.confere(
  (SELECT problema = 'regra_futura' AND acao = 'criar' FROM simular_definicao_taxa(pg_temp.u('P'),
     '[{"tipo_parceiro":"mecanica","servico":"combustivel","uf":"RJ","componente":"base","valor":2500}]'::jsonb)),
  'simulação marca "regra_futura"');
SELECT pg_temp.espera_erro($$SELECT pg_temp.sol('S', '[{"tipo_parceiro":"mecanica","servico":"combustivel","uf":"RJ","componente":"base","valor":2500}]')$$,
  'SC021', 'regra futura agendada no escopo é recusada');

-- ---------- A aprovação refaz as checagens ----------
-- L3 (de Q) está em aberto; enquanto isso, a regra é definida por migração (outro caminho).
DO $$
DECLARE v_instante timestamptz := clock_timestamp();
BEGIN
  UPDATE regra_taxa SET fim_vigencia = v_instante
   WHERE tipo_parceiro_codigo = 'mecanica' AND servico_codigo = 'pneu' AND uf IS NULL AND componente = 'base'
     AND fim_vigencia IS NULL;
  INSERT INTO regra_taxa (tipo_parceiro_codigo, servico_codigo, uf, componente, unidade, valor, situacao, observacao, inicio_vigencia)
  VALUES ('mecanica', 'pneu', NULL, 'base', 'centavos', 6500, 'definido', '[TESTE] por migração', v_instante);
END $$;
SELECT pg_temp.espera_erro($$SELECT aprovar_definicao_taxa(pg_temp.u('P'), pg_temp.id('L3'), '[TESTE]')$$,
  'SC028', 'a aprovação recusa se, depois da solicitação, a regra já foi definida');
SELECT pg_temp.confere(
  (regra_taxa_vigente('mecanica', 'pneu', 'SP', 'base', clock_timestamp())).valor = 6500
  AND (SELECT situacao = 'solicitado' FROM vw_definicao_taxa WHERE id = pg_temp.id('L3'))
  AND NOT EXISTS (SELECT 1 FROM regra_taxa WHERE definicao_id = pg_temp.id('L3')),
  'nada mudou: 6500 continua, L3 segue solicitado e não criou regra');

-- ---------- Somente inserção e restrições ----------
SELECT pg_temp.espera_erro($$UPDATE definicao_taxa SET motivo = 'x' WHERE id = pg_temp.id('L1')$$,
  'SC010', 'lote não é alterado');
SELECT pg_temp.espera_erro($$DELETE FROM definicao_taxa_item WHERE definicao_id = pg_temp.id('L1')$$,
  'SC010', 'item não é apagado');
SELECT pg_temp.espera_erro($$UPDATE definicao_taxa_decisao SET motivo = 'x'$$,
  'SC010', 'decisão não é alterada');
SELECT pg_temp.espera_erro($$TRUNCATE definicao_taxa_decisao$$,
  'SC010', 'TRUNCATE nas decisões é bloqueado');
SELECT pg_temp.espera_erro($$
  INSERT INTO definicao_taxa_item (definicao_id, tipo_parceiro_codigo, servico_codigo, uf, regiao_codigo, componente, unidade, valor)
  VALUES (pg_temp.id('L3'), 'mecanica', 'pneu', 'SP', 'sul', 'minimo', 'centavos', 1)$$,
  '23503', 'item com UF fora da região informada é recusado (FK composta)');
SELECT pg_temp.espera_erro($$
  INSERT INTO regra_taxa (tipo_parceiro_codigo, servico_codigo, uf, componente, unidade, valor, situacao, regra_origem_id)
  VALUES ('chaveiro', 'chaveiro', 'AC', 'base', 'centavos', 1, 'definido', pg_temp.id('L1'))$$,
  '23514', 'regra com origem, mas sem lote (reajuste ou definição), é recusada');
SELECT pg_temp.espera_erro($$
  INSERT INTO regra_taxa (tipo_parceiro_codigo, servico_codigo, uf, componente, unidade, valor, situacao,
                          reajuste_id, regra_origem_id, definicao_id)
  VALUES ('chaveiro', 'chaveiro', 'AC', 'base', 'centavos', 1, 'definido',
          gen_random_uuid(), gen_random_uuid(), pg_temp.id('L1'))$$,
  '23514', 'regra não vem de dois lotes ao mesmo tempo');

-- ---------- Auditoria ----------
SELECT pg_temp.confere(
  EXISTS (SELECT 1 FROM auditoria WHERE acao = 'central_definicao_taxa_solicitada' AND entidade_id = pg_temp.id('L1')
             AND ator_usuario_id = pg_temp.u('S') AND (depois ->> 'itens')::int = 8)
  AND EXISTS (SELECT 1 FROM auditoria WHERE acao = 'central_definicao_taxa_aprovada' AND entidade_id = pg_temp.id('L1')
             AND ator_usuario_id = pg_temp.u('P') AND (depois ->> 'regras_afetadas')::int = 8
             AND antes ->> 'situacao' = 'solicitado' AND depois ->> 'situacao' = 'aprovado')
  AND EXISTS (SELECT 1 FROM auditoria WHERE acao = 'central_definicao_taxa_rejeitada' AND entidade_id = pg_temp.id('L2')
             AND ator_usuario_id = pg_temp.u('P'))
  AND EXISTS (SELECT 1 FROM auditoria WHERE acao = 'central_definicao_taxa_cancelada' AND entidade_id = pg_temp.id('L5')
             AND ator_usuario_id = pg_temp.u('S')),
  'eventos de solicitação, aprovação, rejeição e cancelamento, com o ator de cada um');
SELECT pg_temp.confere(
  (SELECT count(*) = 8 FROM auditoria WHERE entidade = 'regra_taxa' AND acao = 'parametrizacao_insert'
      AND ator_usuario_id = pg_temp.u('P') AND (depois ->> 'definicao_id')::uuid = pg_temp.id('L1'))
  AND (SELECT count(*) = 4 FROM auditoria WHERE entidade = 'regra_taxa' AND acao = 'parametrizacao_update'
      AND ator_usuario_id = pg_temp.u('P') AND antes ->> 'situacao' = 'a_definir'
      AND (depois ->> 'fim_vigencia')::timestamptz = pg_temp.t('inicio_l1'))
  AND (SELECT count(*) = 8 FROM auditoria WHERE entidade = 'definicao_taxa_item' AND ator_usuario_id = pg_temp.u('S')
      AND (depois ->> 'definicao_id')::uuid = pg_temp.id('L1')),
  'regras criadas e encerradas (ator P) e itens (ator S) na auditoria');

-- ---------- Falha da auditoria desfaz a operação ----------
INSERT INTO v (k, id) SELECT 'L6', pg_temp.sol('S', '[{"tipo_parceiro":"chaveiro","servico":"chaveiro","nacional":true,"componente":"base","valor":5000}]');
CREATE FUNCTION public.teste_falhar_auditoria() RETURNS trigger LANGUAGE plpgsql AS $f$
BEGIN
  IF current_setting('teste.falhar_auditoria', true) = 'sim' THEN
    RAISE EXCEPTION '[TESTE] auditoria indisponível' USING ERRCODE = 'TS001';
  END IF;
  RETURN NEW;
END $f$;
CREATE TRIGGER tg_teste_falhar_auditoria BEFORE INSERT ON auditoria
  FOR EACH ROW EXECUTE FUNCTION public.teste_falhar_auditoria();
SET LOCAL teste.falhar_auditoria = 'sim';
SELECT pg_temp.espera_erro($$SELECT aprovar_definicao_taxa(pg_temp.u('P'), pg_temp.id('L6'), '[TESTE] falha')$$,
  'TS001', 'aprovação com a auditoria falhando é recusada');
SELECT pg_temp.espera_erro($$SELECT pg_temp.sol('S', '[{"tipo_parceiro":"chaveiro","servico":"chaveiro","nacional":true,"componente":"minimo","valor":1}]')$$,
  'TS001', 'solicitação com a auditoria falhando é recusada');
SET LOCAL teste.falhar_auditoria = 'nao';
SELECT pg_temp.confere(
  (SELECT situacao = 'solicitado' FROM vw_definicao_taxa WHERE id = pg_temp.id('L6'))
  AND NOT EXISTS (SELECT 1 FROM regra_taxa WHERE definicao_id = pg_temp.id('L6'))
  AND (SELECT situacao = 'a_definir' FROM pg_temp.regra('chaveiro', 'chaveiro', NULL, 'base'))
  AND NOT EXISTS (SELECT 1 FROM definicao_taxa_item WHERE componente = 'minimo' AND servico_codigo = 'chaveiro'),
  'nada ficou gravado: L6 segue solicitado, a regra segue a definir e o lote recusado não existe');

-- ---------- Ator e dados pessoais ----------
SELECT pg_temp.confere(coalesce(current_setting('safetycar.ator_usuario_id', true), '') = '',
  'o ator não fica pendurado depois das funções');
SELECT pg_temp.confere(
  NOT EXISTS (SELECT 1 FROM auditoria
               WHERE (acao LIKE 'central_definicao%' OR entidade IN ('definicao_taxa','definicao_taxa_item',
                                                                       'definicao_taxa_decisao','regra_taxa','regiao','regiao_uf'))
                 AND (coalesce(antes::text, '') || coalesce(depois::text, '')) LIKE '%@%'),
  'nenhum e-mail na auditoria das definições');
