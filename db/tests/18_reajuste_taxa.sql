-- 18 — Reajuste de taxas em lote (0015, com as regras da 0019), como safetycar_migrator.
-- Desde a 0019: só percentual; início imediato; limite de variação copiado no pedido (SC025);
-- um lote em aberto por escopo (SC024); quem pede não aprova nem rejeita; pedir exige
-- solicitar_reajuste_taxa.
-- Valores FICTÍCIOS, em escopos fora da carga inicial da 0012 (que está toda "a definir").
-- Operadores: A (conceder_permissao), S (solicitar), P (aprovar), Q (solicitar e aprovar),
--             X (solicitar, inativo), Z (ativo, sem permissão).
-- O arquivo roda numa só transação: now() é o início dela; as aprovações usam clock_timestamp().

INSERT INTO usuario (id, keycloak_sub, email, perfil, status) VALUES
  ('00000000-0000-4000-8000-0000000d0a01', gen_random_uuid(), 'rj-a@exemplo.invalid', 'central', 'ativo'),
  ('00000000-0000-4000-8000-0000000d0a02', gen_random_uuid(), 'rj-s@exemplo.invalid', 'central', 'ativo'),
  ('00000000-0000-4000-8000-0000000d0a03', gen_random_uuid(), 'rj-p@exemplo.invalid', 'central', 'ativo'),
  ('00000000-0000-4000-8000-0000000d0a04', gen_random_uuid(), 'rj-q@exemplo.invalid', 'central', 'ativo'),
  ('00000000-0000-4000-8000-0000000d0a05', gen_random_uuid(), 'rj-x@exemplo.invalid', 'central', 'ativo'),
  ('00000000-0000-4000-8000-0000000d0a06', gen_random_uuid(), 'rj-z@exemplo.invalid', 'central', 'ativo');

CREATE FUNCTION pg_temp.u(p text) RETURNS uuid LANGUAGE sql IMMUTABLE AS $f$
  SELECT ('00000000-0000-4000-8000-0000000d0a0' ||
          CASE p WHEN 'A' THEN '1' WHEN 'S' THEN '2' WHEN 'P' THEN '3' WHEN 'Q' THEN '4' WHEN 'X' THEN '5' ELSE '6' END)::uuid
$f$;

SELECT conceder_permissao_inicial(pg_temp.u('A'), '[TESTE] administrador');
SELECT cadastrar_operador(pg_temp.u('A'), pg_temp.u(x), '[TESTE] equipe') FROM unnest(ARRAY['S','P','Q','X','Z']) x;
SELECT conceder_permissao(pg_temp.u('A'), pg_temp.u(x), 'solicitar_reajuste_taxa', '[TESTE] solicitante')
  FROM unnest(ARRAY['S','Q','X']) x;
SELECT conceder_permissao(pg_temp.u('A'), pg_temp.u(x), 'aprovar_reajuste_taxa', '[TESTE] aprovador')
  FROM unnest(ARRAY['P','Q']) x;
SELECT definir_operador_ativo(pg_temp.u('A'), pg_temp.u('X'), false, '[TESTE] afastado');

-- Variáveis do teste (ids de regras e lotes, instantes).
CREATE TEMP TABLE v (k text PRIMARY KEY, id uuid, t timestamptz);
CREATE FUNCTION pg_temp.id(p text) RETURNS uuid LANGUAGE sql AS $f$ SELECT id FROM v WHERE k = p $f$;
CREATE FUNCTION pg_temp.t(p text) RETURNS timestamptz LANGUAGE sql AS $f$ SELECT t FROM v WHERE k = p $f$;

CREATE FUNCTION pg_temp.regra(p_k text, p_tipo text, p_servico text, p_uf text, p_comp text, p_unid text,
                              p_valor bigint, p_situacao text DEFAULT 'definido',
                              p_inicio timestamptz DEFAULT now())
RETURNS void LANGUAGE sql AS $f$
  WITH i AS (
    INSERT INTO regra_taxa (tipo_parceiro_codigo, servico_codigo, uf, componente, unidade, valor, situacao, inicio_vigencia)
    VALUES (p_tipo, p_servico, p_uf, p_comp, p_unid, p_valor, p_situacao, p_inicio)
    RETURNING id)
  INSERT INTO v (k, id) SELECT p_k, id FROM i
$f$;

-- Solicitação resumida (percentual).
CREATE FUNCTION pg_temp.sol(p_ator text, p_pct numeric, p_tipo text, p_servico text, p_comp text[],
                            p_nac boolean DEFAULT true, p_flag_pb boolean DEFAULT false,
                            p_ufs text[] DEFAULT NULL, p_regioes text[] DEFAULT NULL,
                            p_excecao text DEFAULT NULL)
RETURNS uuid LANGUAGE sql AS $f$
  SELECT solicitar_reajuste_taxa(pg_temp.u(p_ator), p_pct, ARRAY[p_tipo], ARRAY[p_servico], p_ufs, p_regioes,
                                 p_nac, p_comp, p_flag_pb, '[TESTE] reajuste', p_excecao, 'IPCA (fictício)')
$f$;
CREATE FUNCTION pg_temp.sim(p_pct numeric, p_tipo text, p_servico text, p_comp text[],
                            p_nac boolean DEFAULT true, p_flag_pb boolean DEFAULT false,
                            p_ufs text[] DEFAULT NULL, p_regioes text[] DEFAULT NULL)
RETURNS SETOF record LANGUAGE sql AS $f$
  SELECT regra_id, valor_atual, valor_novo, problema, abrangencia
    FROM simular_reajuste_taxa(pg_temp.u('S'), p_pct, ARRAY[p_tipo], ARRAY[p_servico], p_ufs, p_regioes,
                               p_nac, p_comp, p_flag_pb)
$f$;

-- Fotografia de todas as regras de taxa (para provar que nada mudou).
CREATE FUNCTION pg_temp.foto() RETURNS text LANGUAGE sql AS $f$
  SELECT md5(string_agg(to_jsonb(r)::text, '|' ORDER BY r.id)) FROM regra_taxa r
$f$;
CREATE FUNCTION pg_temp.guarda_foto(p_k text) RETURNS void LANGUAGE sql AS $f$
  INSERT INTO v (k, id) VALUES (p_k, md5(pg_temp.foto())::uuid)
  ON CONFLICT (k) DO UPDATE SET id = EXCLUDED.id
$f$;
CREATE FUNCTION pg_temp.foto_igual(p_k text) RETURNS boolean LANGUAGE sql AS $f$
  SELECT md5(pg_temp.foto())::uuid = pg_temp.id(p_k)
$f$;
CREATE FUNCTION pg_temp.valor_vigente(p_tipo text, p_servico text, p_uf text, p_comp text, p_em timestamptz)
RETURNS bigint LANGUAGE sql AS $f$ SELECT (regra_taxa_vigente(p_tipo, p_servico, p_uf, p_comp, p_em)).valor $f$;

-- Regras FICTÍCIAS
SELECT pg_temp.regra('n_base',  'chaveiro', 'pneu', NULL, 'base',                'centavos',        10000);
SELECT pg_temp.regra('sp_base', 'chaveiro', 'pneu', 'SP', 'base',                'centavos',        12000);
SELECT pg_temp.regra('n_km',    'chaveiro', 'pneu', NULL, 'por_km',              'centavos_por_km',   300);
SELECT pg_temp.regra('n_min',   'chaveiro', 'pneu', NULL, 'minimo',              'centavos',         5000);
SELECT pg_temp.regra('sp_canc', 'chaveiro', 'pneu', 'SP', 'cancelamento',        'centavos',         1650);
SELECT pg_temp.regra('rj_canc', 'chaveiro', 'pneu', 'RJ', 'cancelamento',        'pontos_base',      1000);
SELECT pg_temp.regra('n_com',   'chaveiro', 'pneu', NULL, 'comissao_plataforma', 'pontos_base',      1500);
SELECT pg_temp.regra('n_nc',    'chaveiro', 'pneu', NULL, 'nao_comparecimento',  'centavos',            1);
SELECT pg_temp.regra('sp_bat',  'chaveiro', 'bateria', 'SP', 'base',             'centavos',         2000);
SELECT pg_temp.regra('rj_bat',  'chaveiro', 'bateria', 'RJ', 'base',             'centavos',         2500);
SELECT pg_temp.regra('m_base',  'mecanica', 'chaveiro', NULL, 'base',            'centavos',         4000);
SELECT pg_temp.regra('m_min',   'mecanica', 'chaveiro', NULL, 'minimo',          'centavos',            3);
SELECT pg_temp.regra('m_com',   'mecanica', 'chaveiro', NULL, 'comissao_plataforma', 'pontos_base',  9600);
SELECT pg_temp.regra('c_base',  'chaveiro', 'combustivel', NULL, 'base',         'centavos',        10005);
SELECT pg_temp.regra('c_sp',    'chaveiro', 'combustivel', 'SP', 'base',         'centavos',        10004);
SELECT pg_temp.regra('c_rj',    'chaveiro', 'combustivel', 'RJ', 'base',         'centavos',        10005);

-- ======================================================================
-- Arredondamento: 0,5 ou mais sobe; menos de 0,5 desce (numeric)
-- ======================================================================
SELECT pg_temp.confere(arredondar_centavos(1.5) = 2,   'arredondamento: 1,5 vira 2');
SELECT pg_temp.confere(arredondar_centavos(1.49) = 1,  'arredondamento: 1,49 vira 1');
SELECT pg_temp.confere(arredondar_centavos(2.5) = 3,   'arredondamento: 2,5 vira 3');
SELECT pg_temp.confere(arredondar_centavos(0.5) = 1,   'arredondamento: 0,5 vira 1');
SELECT pg_temp.confere(arredondar_centavos(0.49) = 0,  'arredondamento: 0,49 vira 0');
SELECT pg_temp.confere(arredondar_centavos(1732.5) = 1733 AND arredondar_centavos(1732.4999) = 1732,
  'arredondamento: 1732,5 vira 1733; 1732,4999 vira 1732');
SELECT pg_temp.espera_erro($$SELECT arredondar_centavos(NULL)$$, '22023', 'arredondamento recusa valor nulo');
SELECT pg_temp.confere(
  (SELECT data_type = 'integer' FROM information_schema.columns WHERE table_name = 'reajuste_taxa' AND column_name = 'percentual_bp')
  AND (SELECT data_type = 'integer' FROM information_schema.columns WHERE table_name = 'reajuste_taxa' AND column_name = 'limite_bp_na_criacao'),
  'lote guarda percentual e limite como inteiros em pontos-base (sem ponto flutuante)');
SELECT pg_temp.confere(percentual_para_bp(10) = 1000 AND percentual_para_bp(-2.5) = -250 AND percentual_para_bp(25.55) = 2555,
  'percentual vira pontos-base: 10% = 1000, -2,5% = -250, 25,55% = 2555');

-- ======================================================================
-- Parâmetros inválidos (22023) e assinaturas antigas removidas (42883)
-- ======================================================================
SELECT pg_temp.espera_erro($$SELECT * FROM pg_temp.sim(0, 'chaveiro', 'pneu', '{base}') AS (a uuid, b bigint, c bigint, d text, e text)$$,
  '22023', 'percentual zero é recusado');
SELECT pg_temp.espera_erro($$SELECT * FROM pg_temp.sim(50.01, 'chaveiro', 'pneu', '{base}') AS (a uuid, b bigint, c bigint, d text, e text)$$,
  '22023', 'percentual acima de +50% (teto absoluto) é recusado');
SELECT pg_temp.espera_erro($$SELECT * FROM pg_temp.sim(-50.01, 'chaveiro', 'pneu', '{base}') AS (a uuid, b bigint, c bigint, d text, e text)$$,
  '22023', 'percentual abaixo de -50% é recusado');
SELECT pg_temp.espera_erro($$SELECT * FROM pg_temp.sim(10.005, 'chaveiro', 'pneu', '{base}') AS (a uuid, b bigint, c bigint, d text, e text)$$,
  '22023', 'percentual com mais de 2 casas é recusado');
SELECT pg_temp.espera_erro($$SELECT * FROM pg_temp.sim(NULL, 'chaveiro', 'pneu', '{base}') AS (a uuid, b bigint, c bigint, d text, e text)$$,
  '22023', 'percentual nulo é recusado');
SELECT pg_temp.espera_erro($$SELECT * FROM pg_temp.sim(5, 'chaveiro', 'pneu', '{comissao_plataforma}') AS (a uuid, b bigint, c bigint, d text, e text)$$,
  '22023', 'comissão sem inclui_pontos_base é recusada');
SELECT pg_temp.espera_erro($$SELECT * FROM pg_temp.sim(1, 'chaveiro', 'pneu', '{}') AS (a uuid, b bigint, c bigint, d text, e text)$$,
  '22023', 'lista de componentes vazia é recusada');
SELECT pg_temp.espera_erro($$SELECT * FROM pg_temp.sim(1, 'borracharia', 'pneu', '{base}') AS (a uuid, b bigint, c bigint, d text, e text)$$,
  '22023', 'tipo de parceiro inexistente é recusado');
SELECT pg_temp.espera_erro($$SELECT * FROM pg_temp.sim(1, 'chaveiro', 'pneu', '{base}', true, false, '{XX}') AS (a uuid, b bigint, c bigint, d text, e text)$$,
  '22023', 'UF inválida é recusada');
SELECT pg_temp.espera_erro($$SELECT * FROM pg_temp.sim(1, 'chaveiro', 'pneu', '{base}', true, false, NULL, '{leste}') AS (a uuid, b bigint, c bigint, d text, e text)$$,
  '22023', 'região inexistente é recusada');
SELECT pg_temp.espera_erro($$SELECT * FROM pg_temp.sim(1, 'chaveiro', 'pneu', '{base}', true, false, NULL, '{}') AS (a uuid, b bigint, c bigint, d text, e text)$$,
  '22023', 'lista de regiões vazia é recusada');
SELECT pg_temp.espera_erro($$
  SELECT solicitar_reajuste_taxa(pg_temp.u('S'), 'percentual', 1000, NULL, '{chaveiro}', '{pneu}', NULL, true, '{base}', false, '[TESTE]')$$,
  '42883', 'a assinatura antiga de solicitar (tipo, valor, início) não existe mais');
SELECT pg_temp.espera_erro($$SELECT aprovar_reajuste_taxa(pg_temp.u('P'), gen_random_uuid(), '[TESTE]', now() + interval '1 day')$$,
  '42883', 'a aprovação com início informado não existe mais');

-- ======================================================================
-- Quem solicita; motivo; escopo
-- ======================================================================
SELECT pg_temp.espera_erro($$SELECT pg_temp.sol('Z', 10, 'chaveiro', 'pneu', '{base}')$$,
  'SC016', 'operador sem solicitar_reajuste_taxa não solicita');
SELECT pg_temp.espera_erro($$SELECT pg_temp.sol('P', 10, 'chaveiro', 'pneu', '{base}')$$,
  'SC016', 'o aprovador sem solicitar_reajuste_taxa não solicita');
SELECT pg_temp.espera_erro($$SELECT pg_temp.sol('X', 10, 'chaveiro', 'pneu', '{base}')$$,
  'SC016', 'operador inativo não solicita');
SELECT pg_temp.espera_erro($$
  SELECT solicitar_reajuste_taxa(gen_random_uuid(), 10, '{chaveiro}', '{pneu}', NULL, NULL, true, '{base}', false, '[TESTE]')$$,
  'SC016', 'quem não é operador não solicita');
SELECT pg_temp.espera_erro($$
  SELECT solicitar_reajuste_taxa(pg_temp.u('S'), 10, '{chaveiro}', '{pneu}', NULL, NULL, true, '{base}', false, '   ')$$,
  '22023', 'solicitação sem motivo é recusada');
SELECT pg_temp.espera_erro($$SELECT pg_temp.sol('S', 10, 'chaveiro', 'guincho_leve', '{base}')$$,
  'SC019', 'escopo vazio é recusado');

-- ======================================================================
-- Simulação (só leitura)
-- ======================================================================
SELECT pg_temp.espera_erro($$
  SELECT count(*) FROM simular_reajuste_taxa(pg_temp.u('Z'), 10, '{chaveiro}', '{pneu}', NULL, NULL, true, '{base}', false)$$,
  'SC016', 'sem solicitar nem aprovar, não simula');
SELECT pg_temp.confere(
  (SELECT count(*) = 2 FROM simular_reajuste_taxa(pg_temp.u('P'), 10, '{chaveiro}', '{pneu}', NULL, NULL, true, '{base}', false)),
  'o aprovador simula');
SELECT pg_temp.guarda_foto('antes_sim');
SELECT pg_temp.confere(
  (SELECT count(*) = 4
          AND bool_and(problema IS NULL)
          AND sum(valor_novo) FILTER (WHERE regra_id = pg_temp.id('n_base')) = 11000
          AND sum(valor_novo) FILTER (WHERE regra_id = pg_temp.id('sp_base')) = 13200
          AND sum(valor_novo) FILTER (WHERE regra_id = pg_temp.id('n_km')) = 330
          AND sum(valor_novo) FILTER (WHERE regra_id = pg_temp.id('n_min')) = 5500
     FROM pg_temp.sim(10, 'chaveiro', 'pneu', '{base,minimo,por_km}') AS (regra_id uuid, valor_atual bigint, valor_novo bigint, problema text, abrangencia text)),
  'simulação +10%: base nacional 11000, base SP 13200, por km 330, mínimo 5500 (só monetários)');
SELECT pg_temp.confere(
  (SELECT abrangencia LIKE 'nacional: vale para todas as UFs%'
     FROM pg_temp.sim(10, 'chaveiro', 'pneu', '{base}') AS (regra_id uuid, valor_atual bigint, valor_novo bigint, problema text, abrangencia text)
    WHERE regra_id = pg_temp.id('n_base')),
  'simulação deixa claro que a regra nacional vale para todas as UFs');
SELECT pg_temp.confere(
  (SELECT count(*) = 1 AND bool_and(regra_id = pg_temp.id('sp_base'))
     FROM pg_temp.sim(10, 'chaveiro', 'pneu', '{base}', false) AS (regra_id uuid, valor_atual bigint, valor_novo bigint, problema text, abrangencia text)),
  'sem inclui_nacional, a regra nacional fica fora (só a da UF)');
SELECT pg_temp.confere(
  (SELECT count(*) = 1 AND bool_and(regra_id = pg_temp.id('sp_base'))
     FROM pg_temp.sim(10, 'chaveiro', 'pneu', '{base}', false, false, NULL, '{sudeste}') AS (regra_id uuid, valor_atual bigint, valor_novo bigint, problema text, abrangencia text))
  AND (SELECT count(*) = 0
     FROM pg_temp.sim(10, 'chaveiro', 'pneu', '{base}', false, false, NULL, '{sul}') AS (regra_id uuid, valor_atual bigint, valor_novo bigint, problema text, abrangencia text)),
  'região como atalho: Sudeste alcança a regra de SP; Sul não alcança nada');
SELECT pg_temp.confere(
  (SELECT valor_novo = 1 AND problema = 'sem_alteracao'
     FROM pg_temp.sim(-50, 'chaveiro', 'pneu', '{nao_comparecimento}') AS (regra_id uuid, valor_atual bigint, valor_novo bigint, problema text, abrangencia text)),
  'com o teto de 50%, um valor positivo nunca zera: 1 centavo - 50% = 0,5, que arredonda para 1');
SELECT pg_temp.confere(pg_temp.foto_igual('antes_sim'), 'simulação não altera nenhuma regra');

-- ======================================================================
-- Solicitar não altera nenhuma regra; limite copiado
-- ======================================================================
SELECT pg_temp.guarda_foto('antes_l1');
INSERT INTO v (k, id) SELECT 'L1', pg_temp.sol('S', 10, 'chaveiro', 'pneu', '{base,minimo,por_km}');
SELECT pg_temp.confere(pg_temp.foto_igual('antes_l1'), 'solicitar não altera nenhuma regra');
SELECT pg_temp.confere(
  (SELECT situacao = 'solicitado' AND solicitado_por = pg_temp.u('S') AND tipo = 'percentual' AND percentual_bp = 1000
          AND limite_bp_na_criacao = 2000 AND motivo_excecao IS NULL AND inicio_solicitado IS NULL
     FROM vw_reajuste_taxa WHERE id = pg_temp.id('L1')),
  'lote "solicitado": 10% (1000 pb), limite copiado de 20% (2000 pb), sem exceção, início na aprovação');
SELECT pg_temp.confere(
  (SELECT count(*) = 4 FROM simular_reajuste_taxa(pg_temp.u('P'), pg_temp.id('L1'))),
  'simulação do lote solicitado mostra as 4 regras');

-- ---------- Um lote em aberto por escopo (SC024) ----------
SELECT pg_temp.espera_erro($$SELECT pg_temp.sol('Q', 5, 'chaveiro', 'pneu', '{base}', false, false, '{SP}')$$,
  'SC024', 'outro lote com regra em comum (base de SP), com L1 em aberto, é recusado');
SELECT pg_temp.espera_erro($$SELECT pg_temp.sol('Q', 5, 'chaveiro', 'pneu', '{base}', false, false, NULL, '{sudeste}')$$,
  'SC024', 'também quando a sobreposição vem da região');
INSERT INTO v (k, id) SELECT 'L5', pg_temp.sol('S', 10, 'chaveiro', 'bateria', '{base}', false);
SELECT pg_temp.confere(pg_temp.id('L5') IS NOT NULL, 'lote de escopo disjunto convive com L1');

-- ======================================================================
-- Quem aprova; quem pede não decide
-- ======================================================================
SELECT pg_temp.espera_erro($$SELECT aprovar_reajuste_taxa(pg_temp.u('S'), pg_temp.id('L1'), '[TESTE]')$$,
  'SC016', 'solicitante sem a permissão não aprova');
SELECT pg_temp.espera_erro($$SELECT aprovar_reajuste_taxa(pg_temp.u('A'), pg_temp.id('L1'), '[TESTE]')$$,
  'SC016', 'conceder_permissao não dá poder de aprovar reajuste');
SELECT pg_temp.espera_erro($$SELECT aprovar_reajuste_taxa(pg_temp.u('P'), pg_temp.id('L1'), '')$$,
  '22023', 'aprovação sem motivo é recusada');
UPDATE usuario SET status = 'suspenso' WHERE id = pg_temp.u('P');
SELECT pg_temp.espera_erro($$SELECT aprovar_reajuste_taxa(pg_temp.u('P'), pg_temp.id('L1'), '[TESTE]')$$,
  'SC016', 'aprovador suspenso não aprova');
UPDATE usuario SET status = 'ativo' WHERE id = pg_temp.u('P');

INSERT INTO v (k, id) SELECT 'L2', pg_temp.sol('Q', 5, 'mecanica', 'chaveiro', '{base}');
SELECT pg_temp.espera_erro($$SELECT aprovar_reajuste_taxa(pg_temp.u('Q'), pg_temp.id('L2'), '[TESTE]')$$,
  'SC017', 'quem solicitou não aprova o próprio pedido, mesmo com a permissão');
SELECT pg_temp.espera_erro($$SELECT rejeitar_reajuste_taxa(pg_temp.u('Q'), pg_temp.id('L2'), '[TESTE]')$$,
  'SC017', 'quem solicitou também não rejeita o próprio pedido (cancela)');
SELECT pg_temp.espera_erro($$UPDATE permissao_central SET permite_autoaprovacao = true WHERE codigo = 'aprovar_reajuste_taxa'$$,
  '23514', 'a autoaprovação do reajuste não pode ser ligada (sempre 1 aprovador diferente)');
SELECT pg_temp.confere(aprovar_reajuste_taxa(pg_temp.u('P'), pg_temp.id('L2'), '[TESTE] aprovado') = 1,
  'P aprova o lote de Q (mecânica 4000 → 4200)');

-- ======================================================================
-- Aprovar: encerra as antigas e cria as novas no mesmo instante, imediato
-- ======================================================================
SELECT pg_temp.confere(aprovar_reajuste_taxa(pg_temp.u('P'), pg_temp.id('L1'), '[TESTE] aprovado') = 4,
  'aprovação de L1 afeta 4 regras');
INSERT INTO v (k, t) SELECT 'inicio_l1', inicio_efetivo FROM reajuste_taxa_decisao WHERE reajuste_id = pg_temp.id('L1');
SELECT pg_temp.confere(
  (SELECT situacao = 'aprovado' AND regras_afetadas = 4 AND NOT autoaprovacao AND decidido_por = pg_temp.u('P')
          AND inicio_efetivo >= now() AND inicio_efetivo <= clock_timestamp()
     FROM vw_reajuste_taxa WHERE id = pg_temp.id('L1')),
  'decisão: aprovado por P, 4 regras, início no momento da aprovação (relógio do servidor, nunca no passado)');
SELECT pg_temp.confere(
  (SELECT bool_and(fim_vigencia = pg_temp.t('inicio_l1')) AND count(*) = 4
     FROM regra_taxa WHERE id IN (pg_temp.id('n_base'), pg_temp.id('sp_base'), pg_temp.id('n_km'), pg_temp.id('n_min'))),
  'as 4 regras antigas foram encerradas exatamente no início');
SELECT pg_temp.confere(
  (SELECT count(*) = 4
          AND bool_and(n.inicio_vigencia = pg_temp.t('inicio_l1') AND n.fim_vigencia IS NULL
                       AND n.situacao = 'definido' AND n.regra_origem_id = o.id
                       AND n.tipo_parceiro_codigo = o.tipo_parceiro_codigo AND n.servico_codigo = o.servico_codigo
                       AND n.uf IS NOT DISTINCT FROM o.uf AND n.componente = o.componente AND n.unidade = o.unidade
                       AND n.base_distancia IS NOT DISTINCT FROM o.base_distancia)
     FROM regra_taxa n JOIN regra_taxa o ON o.id = n.regra_origem_id
    WHERE n.reajuste_id = pg_temp.id('L1')),
  'as 4 regras novas começam no início, copiam o escopo e apontam para a regra substituída e o lote');
SELECT pg_temp.confere(
  (SELECT array_agg(n.valor ORDER BY n.valor) = '{330,5500,11000,13200}'
     FROM regra_taxa n WHERE n.reajuste_id = pg_temp.id('L1')),
  'valores novos: 330, 5500, 11000 e 13200');
SELECT pg_temp.confere(
  (SELECT count(*) = 4 AND bool_and(valor_novo = round(valor_base * 1.10))
     FROM vw_reajuste_taxa_regra WHERE reajuste_id = pg_temp.id('L1')),
  'vw_reajuste_taxa_regra mostra valor base e valor novo de cada regra');
SELECT pg_temp.confere(
  (SELECT bool_and(fim_vigencia IS NULL AND reajuste_id IS NULL) FROM regra_taxa
    WHERE id IN (pg_temp.id('sp_canc'), pg_temp.id('rj_canc'), pg_temp.id('n_com'), pg_temp.id('n_nc'))),
  'comissão, cancelamentos e não comparecimento (fora do pedido) ficaram intactos');
SELECT pg_temp.confere(
  NOT EXISTS (SELECT 1 FROM regra_taxa a JOIN regra_taxa b
                ON a.id < b.id AND a.tipo_parceiro_codigo = b.tipo_parceiro_codigo
               AND a.servico_codigo = b.servico_codigo AND a.componente = b.componente
               AND a.uf IS NOT DISTINCT FROM b.uf
               AND tstzrange(a.inicio_vigencia, a.fim_vigencia, '[)') && tstzrange(b.inicio_vigencia, b.fim_vigencia, '[)'))
  AND (SELECT bool_and(o.fim_vigencia = n.inicio_vigencia) FROM regra_taxa n JOIN regra_taxa o ON o.id = n.regra_origem_id
        WHERE n.reajuste_id = pg_temp.id('L1')),
  'antiga encerrada e nova iniciada no mesmo instante, sem sobreposição de vigência');
SELECT pg_temp.confere(
  EXISTS (SELECT 1 FROM pg_locks WHERE locktype = 'advisory' AND pid = pg_backend_pid() AND objid = 150001),
  'aprovação obteve o lock de serialização (pg_advisory_xact_lock)');
SELECT pg_temp.confere(coalesce(current_setting('safetycar.ator_usuario_id', true), '') = '',
  'o ator não fica pendurado depois da aprovação');

-- ---------- Chamado em andamento (direito adquirido): consulta por data ----------
SELECT pg_temp.confere(
  pg_temp.valor_vigente('chaveiro', 'pneu', 'SP', 'base', pg_temp.t('inicio_l1') - interval '1 microsecond') = 12000,
  'instante anterior ao início devolve a regra antiga (SP 12000)');
SELECT pg_temp.confere(
  pg_temp.valor_vigente('chaveiro', 'pneu', 'SP', 'base', pg_temp.t('inicio_l1')) = 13200,
  'instante igual ao início devolve a regra nova (SP 13200)');
SELECT pg_temp.confere(
  pg_temp.valor_vigente('chaveiro', 'pneu', 'RJ', 'base', pg_temp.t('inicio_l1') - interval '1 microsecond') = 10000
  AND pg_temp.valor_vigente('chaveiro', 'pneu', 'RJ', 'base', pg_temp.t('inicio_l1')) = 11000,
  'RJ (sem regra própria) segue a nacional: 10000 antes, 11000 a partir do início');
SELECT pg_temp.confere((SELECT valor = 12000 FROM regra_taxa WHERE id = pg_temp.id('sp_base')),
  'regra antiga continua consultável pelo id');

-- ---------- Imutabilidade da 0010 ----------
SELECT pg_temp.espera_erro($$UPDATE regra_taxa SET valor = 1 WHERE id = pg_temp.id('sp_base')$$,
  'SC012', 'regra antiga: valor não muda');
SELECT pg_temp.espera_erro($$UPDATE regra_taxa SET observacao = 'x' WHERE id = pg_temp.id('sp_base')$$,
  'SC012', 'regra antiga: observação não muda');
SELECT pg_temp.espera_erro($$UPDATE regra_taxa SET inicio_vigencia = inicio_vigencia - interval '1 day' WHERE id = pg_temp.id('sp_base')$$,
  'SC012', 'regra antiga: início não muda');
SELECT pg_temp.espera_erro($$DELETE FROM regra_taxa WHERE id = pg_temp.id('sp_base')$$,
  'SC012', 'regra antiga: não é excluída');
SELECT pg_temp.espera_erro($$UPDATE regra_taxa SET valor = 1 WHERE reajuste_id = pg_temp.id('L1')$$,
  'SC012', 'regra nova também é imutável');

-- ---------- Lote decidido não se decide de novo ----------
SELECT pg_temp.espera_erro($$SELECT aprovar_reajuste_taxa(pg_temp.u('Q'), pg_temp.id('L1'), '[TESTE] de novo')$$,
  'SC020', 'lote aprovado não é aprovado de novo');
SELECT pg_temp.espera_erro($$SELECT rejeitar_reajuste_taxa(pg_temp.u('Q'), pg_temp.id('L1'), '[TESTE]')$$,
  'SC020', 'lote aprovado não é rejeitado');
SELECT pg_temp.espera_erro($$SELECT cancelar_reajuste_taxa(pg_temp.u('S'), pg_temp.id('L1'), '[TESTE]')$$,
  'SC020', 'lote aprovado não é cancelado');
SELECT pg_temp.espera_erro($$UPDATE reajuste_taxa SET motivo = 'x'$$, 'SC010', 'lote é somente de inserção');
SELECT pg_temp.espera_erro($$DELETE FROM reajuste_taxa_decisao$$, 'SC010', 'decisão é somente de inserção');

-- ---------- Auditoria com ator ----------
SELECT pg_temp.confere(
  EXISTS (SELECT 1 FROM auditoria WHERE entidade = 'reajuste_taxa' AND acao = 'parametrizacao_insert'
             AND entidade_id = pg_temp.id('L1') AND ator_usuario_id = pg_temp.u('S'))
  AND EXISTS (SELECT 1 FROM auditoria WHERE entidade = 'reajuste_taxa_decisao' AND ator_usuario_id = pg_temp.u('P')
                 AND depois ->> 'reajuste_id' = pg_temp.id('L1')::text AND depois ->> 'situacao' = 'aprovado'),
  'solicitação (ator S) e aprovação (ator P) na auditoria automática');
SELECT pg_temp.confere(
  EXISTS (SELECT 1 FROM auditoria WHERE acao = 'central_reajuste_solicitado' AND entidade_id = pg_temp.id('L1')
             AND ator_usuario_id = pg_temp.u('S') AND (depois ->> 'percentual_bp')::int = 1000
             AND (depois ->> 'limite_bp_na_criacao')::int = 2000 AND NOT (depois ->> 'acima_do_limite')::boolean)
  AND EXISTS (SELECT 1 FROM auditoria WHERE acao = 'central_reajuste_aprovado' AND entidade_id = pg_temp.id('L1')
             AND ator_usuario_id = pg_temp.u('P') AND (depois ->> 'regras_afetadas')::int = 4
             AND antes ->> 'situacao' = 'solicitado'),
  'eventos central_reajuste_solicitado (percentual e limite) e central_reajuste_aprovado (regras afetadas)');
SELECT pg_temp.confere(
  (SELECT count(*) = 4 FROM auditoria WHERE entidade = 'regra_taxa' AND acao = 'parametrizacao_update'
      AND ator_usuario_id = pg_temp.u('P') AND antes ->> 'fim_vigencia' IS NULL
      AND (depois ->> 'fim_vigencia')::timestamptz = pg_temp.t('inicio_l1'))
  AND (SELECT count(*) = 4 FROM auditoria WHERE entidade = 'regra_taxa' AND acao = 'parametrizacao_insert'
      AND ator_usuario_id = pg_temp.u('P') AND depois ->> 'reajuste_id' = pg_temp.id('L1')::text),
  'cada regra encerrada (antes/depois) e cada regra criada estão na auditoria com o ator P');

-- ======================================================================
-- Rejeitar e cancelar não alteram nada
-- ======================================================================
INSERT INTO v (k, id) SELECT 'L3', pg_temp.sol('S', 2, 'chaveiro', 'pneu', '{base}');
SELECT pg_temp.guarda_foto('antes_l3');
SELECT pg_temp.espera_erro($$SELECT rejeitar_reajuste_taxa(pg_temp.u('S'), pg_temp.id('L3'), '[TESTE]')$$,
  'SC016', 'sem a permissão, não rejeita');
SELECT rejeitar_reajuste_taxa(pg_temp.u('Q'), pg_temp.id('L3'), '[TESTE] índice errado');
SELECT pg_temp.confere(pg_temp.foto_igual('antes_l3'), 'rejeitar não altera nenhuma regra');
SELECT pg_temp.confere((SELECT situacao = 'rejeitado' AND decidido_por = pg_temp.u('Q') FROM vw_reajuste_taxa WHERE id = pg_temp.id('L3')),
  'lote rejeitado por Q');
SELECT pg_temp.espera_erro($$SELECT aprovar_reajuste_taxa(pg_temp.u('P'), pg_temp.id('L3'), '[TESTE]')$$,
  'SC020', 'lote rejeitado não é aprovado');

INSERT INTO v (k, id) SELECT 'L4', pg_temp.sol('S', -3, 'chaveiro', 'pneu', '{base}');
SELECT pg_temp.guarda_foto('antes_l4');
SELECT pg_temp.espera_erro($$SELECT cancelar_reajuste_taxa(pg_temp.u('A'), pg_temp.id('L4'), '[TESTE]')$$,
  'SC016', 'quem não é o solicitante nem aprovador não cancela');
SELECT cancelar_reajuste_taxa(pg_temp.u('S'), pg_temp.id('L4'), '[TESTE] desisti');
SELECT pg_temp.confere(pg_temp.foto_igual('antes_l4'), 'cancelar não altera nenhuma regra');
SELECT pg_temp.confere((SELECT situacao = 'cancelado' AND decidido_por = pg_temp.u('S') FROM vw_reajuste_taxa WHERE id = pg_temp.id('L4')),
  'lote cancelado pelo próprio solicitante');
SELECT pg_temp.confere(
  EXISTS (SELECT 1 FROM auditoria WHERE acao = 'central_reajuste_rejeitado' AND entidade_id = pg_temp.id('L3')
             AND ator_usuario_id = pg_temp.u('Q'))
  AND EXISTS (SELECT 1 FROM auditoria WHERE acao = 'central_reajuste_cancelado' AND entidade_id = pg_temp.id('L4')
             AND ator_usuario_id = pg_temp.u('S')),
  'eventos de rejeição e cancelamento, com o ator');

-- ======================================================================
-- "A definir" no escopo: recusa (SC013) sem alterar NADA
-- ======================================================================
SELECT pg_temp.regra('mg_bat', 'chaveiro', 'bateria', 'MG', 'base', 'centavos', 0, 'a_definir');
SELECT pg_temp.guarda_foto('antes_l5');
SELECT pg_temp.espera_erro($$SELECT aprovar_reajuste_taxa(pg_temp.u('P'), pg_temp.id('L5'), '[TESTE]')$$,
  'SC013', 'aprovação com regra "a definir" no escopo é recusada');
SELECT pg_temp.confere(pg_temp.foto_igual('antes_l5'), 'nenhuma regra foi alterada');
SELECT pg_temp.confere(
  (SELECT bool_and(fim_vigencia IS NULL) AND sum(valor) = 4500 FROM regra_taxa
    WHERE id IN (pg_temp.id('sp_bat'), pg_temp.id('rj_bat'))),
  'nem as regras definidas do mesmo escopo (SP 2000, RJ 2500) mudaram');
SELECT pg_temp.confere(
  (SELECT situacao = 'solicitado' FROM vw_reajuste_taxa WHERE id = pg_temp.id('L5'))
  AND NOT EXISTS (SELECT 1 FROM regra_taxa WHERE reajuste_id = pg_temp.id('L5')),
  'lote segue "solicitado" e nenhuma regra nova foi criada');
SELECT pg_temp.espera_erro($$SELECT pg_temp.sol('S', 10, 'chaveiro', 'bateria', '{base}', false)$$,
  'SC013', 'a solicitação já recusa escopo com "a definir"');
SELECT cancelar_reajuste_taxa(pg_temp.u('S'), pg_temp.id('L5'), '[TESTE] escopo com regra a definir');

-- ======================================================================
-- Resultado inválido e "nada a alterar" (SC022)
-- ======================================================================
SELECT pg_temp.espera_erro($$SELECT pg_temp.sol('S', 5, 'mecanica', 'chaveiro', '{comissao_plataforma}', true, true)$$,
  'SC022', 'comissão acima de 10000 pb (9600 + 5% = 10080) é recusada');
SELECT pg_temp.confere(
  (SELECT problema = 'sem_alteracao' AND valor_novo = 3
     FROM pg_temp.sim(1, 'mecanica', 'chaveiro', '{minimo}') AS (regra_id uuid, valor_atual bigint, valor_novo bigint, problema text, abrangencia text)),
  'simulação marca "sem_alteracao" (3 + 1% = 3,03, arredonda para 3)');
SELECT pg_temp.espera_erro($$SELECT pg_temp.sol('S', 1, 'mecanica', 'chaveiro', '{minimo}')$$,
  'SC022', 'nada a alterar: nenhuma regra muda de valor');

-- Valor igual entra como nova versão quando outra regra do lote muda.
INSERT INTO v (k, id) SELECT 'L7', pg_temp.sol('S', 1, 'mecanica', 'chaveiro', '{base,minimo}');
SELECT pg_temp.confere(aprovar_reajuste_taxa(pg_temp.u('Q'), pg_temp.id('L7'), '[TESTE]') = 2,
  'lote misto: base muda e mínimo fica igual; 2 regras ganham nova versão');
SELECT pg_temp.confere(
  (SELECT array_agg(valor ORDER BY componente) = '{4242,3}' FROM regra_taxa WHERE reajuste_id = pg_temp.id('L7')),
  'base 4200 + 1% = 4242; mínimo 3 continua 3, como nova versão');

-- ======================================================================
-- Pontos-base só com pedido explícito; arredondamento no fluxo real; reajuste negativo
-- ======================================================================
INSERT INTO v (k, id) SELECT 'L8', pg_temp.sol('S', 5, 'chaveiro', 'pneu', '{cancelamento,comissao_plataforma}', true, true);
SELECT pg_temp.confere(aprovar_reajuste_taxa(pg_temp.u('Q'), pg_temp.id('L8'), '[TESTE]') = 3,
  'com inclui_pontos_base: cancelamento SP (centavos), cancelamento RJ (pb) e comissão');
SELECT pg_temp.confere(
  (SELECT valor = 1733 FROM regra_taxa WHERE regra_origem_id = pg_temp.id('sp_canc'))
  AND (SELECT valor = 1050 FROM regra_taxa WHERE regra_origem_id = pg_temp.id('rj_canc'))
  AND (SELECT valor = 1575 FROM regra_taxa WHERE regra_origem_id = pg_temp.id('n_com')),
  'cancelamento SP 1650 + 5% = 1732,5 vira 1733; RJ 1000 pb vira 1050; comissão 1500 vira 1575');

INSERT INTO v (k, id) SELECT 'L11', pg_temp.sol('S', 10, 'chaveiro', 'combustivel', '{base}', true, false, '{SP}');
SELECT pg_temp.confere(aprovar_reajuste_taxa(pg_temp.u('P'), pg_temp.id('L11'), '[TESTE]') = 2, 'L11: nacional e SP');
SELECT pg_temp.confere(
  (SELECT valor = 11006 FROM regra_taxa WHERE regra_origem_id = pg_temp.id('c_base'))
  AND (SELECT valor = 11004 FROM regra_taxa WHERE regra_origem_id = pg_temp.id('c_sp')),
  'R$ 100,05 + 10% = R$ 110,06 (110,055: meio centavo sobe); R$ 100,04 + 10% = R$ 110,04 (110,044 desce)');
INSERT INTO v (k, id) SELECT 'L12', pg_temp.sol('S', -10, 'chaveiro', 'combustivel', '{base}', false, false, '{RJ}');
-- Aprovação e conferência em instruções separadas: na mesma instrução, a subconsulta não
-- enxergaria a regra criada pela aprovação (snapshot do início da instrução).
SELECT pg_temp.confere(aprovar_reajuste_taxa(pg_temp.u('P'), pg_temp.id('L12'), '[TESTE] deflação') = 1, 'L12: RJ');
SELECT pg_temp.confere((SELECT valor = 9005 FROM regra_taxa WHERE regra_origem_id = pg_temp.id('c_rj')),
  'reajuste negativo: R$ 100,05 - 10% = R$ 90,05 (90,045: meio centavo sobe)');

INSERT INTO v (k, id) SELECT 'L9', pg_temp.sol('S', -10, 'chaveiro', 'pneu', '{minimo}');
SELECT pg_temp.confere(aprovar_reajuste_taxa(pg_temp.u('P'), pg_temp.id('L9'), '[TESTE] deflação') = 1, 'L9: mínimo');
SELECT pg_temp.confere((SELECT valor = 4950 FROM regra_taxa WHERE reajuste_id = pg_temp.id('L9')),
  'mínimo 5500 - 10% = 4950');

-- ======================================================================
-- Limite de variação (SC025): o limite usado é o copiado no pedido
-- ======================================================================
INSERT INTO v (k, id) SELECT 'L13', pg_temp.sol('S', 20, 'mecanica', 'chaveiro', '{base}');
SELECT pg_temp.confere(
  (SELECT motivo_excecao IS NULL AND limite_bp_na_criacao = 2000 FROM reajuste_taxa WHERE id = pg_temp.id('L13')),
  'exatamente no limite (20%) não exige exceção');
SELECT cancelar_reajuste_taxa(pg_temp.u('S'), pg_temp.id('L13'), '[TESTE] só para conferir o limite');
SELECT pg_temp.espera_erro($$SELECT pg_temp.sol('S', 20.01, 'mecanica', 'chaveiro', '{base}')$$,
  'SC025', 'acima do limite sem motivo de exceção é recusado');
SELECT pg_temp.espera_erro($$SELECT pg_temp.sol('S', -25, 'mecanica', 'chaveiro', '{base}', true, false, NULL, NULL, '   ')$$,
  'SC025', 'motivo de exceção em branco não vale (também para reajuste negativo)');
INSERT INTO v (k, id) SELECT 'L14', pg_temp.sol('S', 25, 'mecanica', 'chaveiro', '{base}', true, false, NULL, NULL, '[TESTE] dissídio da categoria');
SELECT pg_temp.confere(
  (SELECT motivo_excecao = '[TESTE] dissídio da categoria' AND percentual_bp = 2500 FROM reajuste_taxa WHERE id = pg_temp.id('L14'))
  AND EXISTS (SELECT 1 FROM auditoria WHERE acao = 'central_reajuste_solicitado' AND entidade_id = pg_temp.id('L14')
                 AND (depois ->> 'acima_do_limite')::boolean AND depois ->> 'motivo_excecao' = '[TESTE] dissídio da categoria'),
  'acima do limite com motivo de exceção é aceito e fica na auditoria');

INSERT INTO v (k, id) SELECT 'L15', pg_temp.sol('S', 15, 'chaveiro', 'pneu', '{por_km}');
-- O limite passa a 10% (por migração, outro caminho), com L15 (15%) em aberto.
DO $$
DECLARE v_instante timestamptz := clock_timestamp();
BEGIN
  UPDATE parametro_valor SET fim_vigencia = v_instante
   WHERE parametro_chave = 'limite_variacao_reajuste' AND fim_vigencia IS NULL;
  INSERT INTO parametro_valor (parametro_chave, valor, origem, motivo, inicio_vigencia)
  VALUES ('limite_variacao_reajuste', 10, 'migracao', '[TESTE] limite menor', v_instante);
END $$;
SELECT pg_temp.confere(aprovar_reajuste_taxa(pg_temp.u('P'), pg_temp.id('L15'), '[TESTE]') = 1
  AND (SELECT limite_bp_na_criacao = 2000 FROM reajuste_taxa WHERE id = pg_temp.id('L15')),
  'L15 (15%) é aprovado: vale o limite copiado no pedido (20%), não o de agora (10%)');
SELECT pg_temp.confere(aprovar_reajuste_taxa(pg_temp.u('P'), pg_temp.id('L14'), '[TESTE] exceção aceita') = 1,
  'L14 (25%, com exceção) é aprovado');
SELECT pg_temp.confere((SELECT valor = 5303 FROM regra_taxa WHERE reajuste_id = pg_temp.id('L14')),
  'L14 (25%, com exceção) é aprovado: 4242 + 25% = 5302,5 vira 5303');
SELECT pg_temp.espera_erro($$SELECT pg_temp.sol('S', 15, 'chaveiro', 'combustivel', '{base}', true, false, '{SP}')$$,
  'SC025', 'um pedido novo de 15% já usa o limite de agora (10%)');
SELECT pg_temp.espera_erro($$
  INSERT INTO reajuste_taxa (tipo, percentual_bp, componentes, inclui_nacional, motivo, solicitado_por, limite_bp_na_criacao)
  VALUES ('percentual', 1500, '{base}', true, '[TESTE] direto', pg_temp.u('S'), 5000)$$,
  'SC025', 'o limite enviado é ignorado: vale o do parâmetro (também por INSERT direto)');
SELECT pg_temp.espera_erro($$
  INSERT INTO reajuste_taxa (tipo, valor_centavos, componentes, inclui_nacional, motivo, solicitado_por)
  VALUES ('valor', 100, '{base}', true, '[TESTE] direto', pg_temp.u('S'))$$,
  '22023', 'lote por valor não entra mais, nem por INSERT direto');
SELECT pg_temp.espera_erro($$
  INSERT INTO reajuste_taxa (tipo, percentual_bp, componentes, inclui_nacional, motivo, solicitado_por, inicio_solicitado)
  VALUES ('percentual', 100, '{base}', true, '[TESTE] direto', pg_temp.u('S'), now() + interval '1 day')$$,
  '22023', 'lote com início agendado não entra mais, nem por INSERT direto');

-- ======================================================================
-- Regra futura agendada no escopo (SC021)
-- ======================================================================
SELECT pg_temp.regra('rj_km_futura', 'chaveiro', 'pneu', 'RJ', 'por_km', 'centavos_por_km', 400, 'definido',
                     now() + interval '1 day');
SELECT pg_temp.espera_erro($$SELECT pg_temp.sol('S', 5, 'chaveiro', 'pneu', '{por_km}')$$,
  'SC021', 'regra futura agendada no escopo (por km do RJ a partir de amanhã) recusa');

-- ======================================================================
-- Falha da auditoria desfaz a operação
-- ======================================================================
INSERT INTO v (k, id) SELECT 'L16', pg_temp.sol('S', 5, 'chaveiro', 'combustivel', '{base}', true, false, '{SP}');
CREATE FUNCTION public.teste_falhar_auditoria() RETURNS trigger LANGUAGE plpgsql AS $f$
BEGIN
  IF current_setting('teste.falhar_auditoria', true) = 'sim' THEN
    RAISE EXCEPTION '[TESTE] auditoria indisponível' USING ERRCODE = 'TS001';
  END IF;
  RETURN NEW;
END $f$;
CREATE TRIGGER tg_teste_falhar_auditoria BEFORE INSERT ON auditoria
  FOR EACH ROW EXECUTE FUNCTION public.teste_falhar_auditoria();
SELECT pg_temp.guarda_foto('antes_l16');
SET LOCAL teste.falhar_auditoria = 'sim';
SELECT pg_temp.espera_erro($$SELECT aprovar_reajuste_taxa(pg_temp.u('P'), pg_temp.id('L16'), '[TESTE] falha')$$,
  'TS001', 'aprovação com a auditoria falhando é recusada');
SELECT pg_temp.espera_erro($$SELECT pg_temp.sol('S', 5, 'chaveiro', 'bateria', '{base}', false, false, '{SP}')$$,
  'TS001', 'solicitação com a auditoria falhando é recusada');
SET LOCAL teste.falhar_auditoria = 'nao';
SELECT pg_temp.confere(
  pg_temp.foto_igual('antes_l16')
  AND (SELECT situacao = 'solicitado' FROM vw_reajuste_taxa WHERE id = pg_temp.id('L16'))
  AND NOT EXISTS (SELECT 1 FROM reajuste_taxa WHERE servicos = '{bateria}' AND ufs = '{SP}'),
  'nada ficou gravado: nenhuma regra mudou, L16 segue solicitado e o lote recusado não existe');

-- ======================================================================
-- Sem dado pessoal na auditoria
-- ======================================================================
SELECT pg_temp.confere(
  NOT EXISTS (SELECT 1 FROM auditoria
               WHERE (acao LIKE 'central_reajuste%' OR entidade IN ('reajuste_taxa','reajuste_taxa_decisao','regra_taxa'))
                 AND (coalesce(antes::text, '') || coalesce(depois::text, '')) LIKE '%@%'),
  'nenhum e-mail na auditoria dos reajustes');
