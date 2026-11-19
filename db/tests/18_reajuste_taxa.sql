-- 18 — Reajuste de taxas em lote (0015), como safetycar_migrator (dono das funções).
-- Valores FICTÍCIOS. Escopos fora da carga inicial da 0012 (que está toda "a definir"):
--   PNEU = chaveiro/pneu, BAT = chaveiro/bateria, MEC = mecanica/chaveiro.
-- Operadores: A (conceder_permissao), S (solicitante, sem permissão de aprovar),
--             P e Q (aprovar_reajuste_taxa), X (inativo).

INSERT INTO usuario (id, keycloak_sub, email, perfil, status) VALUES
  ('00000000-0000-4000-8000-0000000d0a01', gen_random_uuid(), 'rj-a@exemplo.invalid', 'central', 'ativo'),
  ('00000000-0000-4000-8000-0000000d0a02', gen_random_uuid(), 'rj-s@exemplo.invalid', 'central', 'ativo'),
  ('00000000-0000-4000-8000-0000000d0a03', gen_random_uuid(), 'rj-p@exemplo.invalid', 'central', 'ativo'),
  ('00000000-0000-4000-8000-0000000d0a04', gen_random_uuid(), 'rj-q@exemplo.invalid', 'central', 'ativo'),
  ('00000000-0000-4000-8000-0000000d0a05', gen_random_uuid(), 'rj-x@exemplo.invalid', 'central', 'ativo');

CREATE FUNCTION pg_temp.u(p text) RETURNS uuid LANGUAGE sql IMMUTABLE AS $f$
  SELECT ('00000000-0000-4000-8000-0000000d0a0' ||
          CASE p WHEN 'A' THEN '1' WHEN 'S' THEN '2' WHEN 'P' THEN '3' WHEN 'Q' THEN '4' ELSE '5' END)::uuid
$f$;

SELECT conceder_permissao_inicial(pg_temp.u('A'), '[TESTE] administrador');
SELECT cadastrar_operador(pg_temp.u('A'), pg_temp.u(x), '[TESTE] equipe') FROM unnest(ARRAY['S','P','Q','X']) x;
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

-- Solicitação resumida: percentual se p_pb não for nulo; senão, por valor.
CREATE FUNCTION pg_temp.sol(p_ator text, p_pb int, p_val bigint, p_tipo text, p_servico text, p_comp text[],
                            p_nac boolean DEFAULT true, p_flag_pb boolean DEFAULT false,
                            p_ufs text[] DEFAULT NULL, p_inicio timestamptz DEFAULT NULL)
RETURNS uuid LANGUAGE sql AS $f$
  SELECT solicitar_reajuste_taxa(pg_temp.u(p_ator), CASE WHEN p_pb IS NULL THEN 'valor' ELSE 'percentual' END,
                                 p_pb, p_val, ARRAY[p_tipo], ARRAY[p_servico], p_ufs, p_nac, p_comp, p_flag_pb,
                                 '[TESTE] reajuste', 'IPCA (fictício)', p_inicio)
$f$;
CREATE FUNCTION pg_temp.sim(p_pb int, p_val bigint, p_tipo text, p_servico text, p_comp text[],
                            p_nac boolean DEFAULT true, p_flag_pb boolean DEFAULT false, p_ufs text[] DEFAULT NULL)
RETURNS SETOF record LANGUAGE sql AS $f$
  SELECT regra_id, valor_atual, valor_novo, problema, abrangencia
    FROM simular_reajuste_taxa(pg_temp.u('S'), CASE WHEN p_pb IS NULL THEN 'valor' ELSE 'percentual' END,
                               p_pb, p_val, ARRAY[p_tipo], ARRAY[p_servico], p_ufs, p_nac, p_comp, p_flag_pb)
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
  (SELECT data_type = 'bigint' FROM information_schema.columns WHERE table_name = 'reajuste_taxa' AND column_name = 'valor_centavos')
  AND (SELECT data_type = 'integer' FROM information_schema.columns WHERE table_name = 'reajuste_taxa' AND column_name = 'percentual_bp'),
  'lote guarda valor e percentual como inteiros (sem ponto flutuante)');

-- ======================================================================
-- Parâmetros inválidos (22023)
-- ======================================================================
SELECT pg_temp.espera_erro($$SELECT * FROM pg_temp.sim(NULL, 100, 'chaveiro', 'pneu', '{por_km}') AS (a uuid, b bigint, c bigint, d text, e text)$$,
  '22023', 'reajuste por valor no componente por km é proibido');
SELECT pg_temp.espera_erro($$SELECT * FROM pg_temp.sim(NULL, 100, 'chaveiro', 'pneu', '{comissao_plataforma}', true, true) AS (a uuid, b bigint, c bigint, d text, e text)$$,
  '22023', 'reajuste por valor em pontos-base é proibido');
SELECT pg_temp.espera_erro($$SELECT * FROM pg_temp.sim(500, NULL, 'chaveiro', 'pneu', '{comissao_plataforma}') AS (a uuid, b bigint, c bigint, d text, e text)$$,
  '22023', 'comissão sem inclui_pontos_base é recusada');
SELECT pg_temp.espera_erro($$SELECT * FROM pg_temp.sim(5001, NULL, 'chaveiro', 'pneu', '{base}') AS (a uuid, b bigint, c bigint, d text, e text)$$,
  '22023', 'percentual acima de +5000 pb é recusado');
SELECT pg_temp.espera_erro($$SELECT * FROM pg_temp.sim(-5001, NULL, 'chaveiro', 'pneu', '{base}') AS (a uuid, b bigint, c bigint, d text, e text)$$,
  '22023', 'percentual abaixo de -5000 pb é recusado');
SELECT pg_temp.espera_erro($$SELECT * FROM pg_temp.sim(0, NULL, 'chaveiro', 'pneu', '{base}') AS (a uuid, b bigint, c bigint, d text, e text)$$,
  '22023', 'percentual zero é recusado');
SELECT pg_temp.espera_erro($$SELECT * FROM pg_temp.sim(100, NULL, 'chaveiro', 'pneu', '{}') AS (a uuid, b bigint, c bigint, d text, e text)$$,
  '22023', 'lista de componentes vazia é recusada');
SELECT pg_temp.espera_erro($$SELECT * FROM pg_temp.sim(100, NULL, 'borracharia', 'pneu', '{base}') AS (a uuid, b bigint, c bigint, d text, e text)$$,
  '22023', 'tipo de parceiro inexistente é recusado');
SELECT pg_temp.espera_erro($$SELECT * FROM pg_temp.sim(100, NULL, 'chaveiro', 'pneu', '{base}', true, false, '{XX}') AS (a uuid, b bigint, c bigint, d text, e text)$$,
  '22023', 'UF inválida é recusada');

-- ======================================================================
-- Quem solicita; motivo; início; escopo
-- ======================================================================
SELECT pg_temp.espera_erro($$SELECT pg_temp.sol('X', 1000, NULL, 'chaveiro', 'pneu', '{base}')$$,
  'SC016', 'operador inativo não solicita');
SELECT pg_temp.espera_erro($$
  SELECT solicitar_reajuste_taxa(gen_random_uuid(), 'percentual', 1000, NULL, '{chaveiro}', '{pneu}', NULL, true, '{base}', false, '[TESTE]')$$,
  'SC016', 'quem não é operador não solicita');
SELECT pg_temp.espera_erro($$
  SELECT solicitar_reajuste_taxa(pg_temp.u('S'), 'percentual', 1000, NULL, '{chaveiro}', '{pneu}', NULL, true, '{base}', false, '   ')$$,
  '22023', 'solicitação sem motivo é recusada');
SELECT pg_temp.espera_erro($$SELECT pg_temp.sol('S', 1000, NULL, 'chaveiro', 'pneu', '{base}', true, false, NULL, now() - interval '1 minute')$$,
  'SC012', 'solicitação com início no passado é recusada');
SELECT pg_temp.espera_erro($$SELECT pg_temp.sol('S', 1000, NULL, 'chaveiro', 'combustivel', '{base}')$$,
  'SC019', 'escopo vazio é recusado');

-- ======================================================================
-- Simulação (só leitura)
-- ======================================================================
SELECT pg_temp.guarda_foto('antes_sim');
SELECT pg_temp.confere(
  (SELECT count(*) = 4
          AND bool_and(problema IS NULL)
          AND sum(valor_novo) FILTER (WHERE regra_id = pg_temp.id('n_base')) = 11000
          AND sum(valor_novo) FILTER (WHERE regra_id = pg_temp.id('sp_base')) = 13200
          AND sum(valor_novo) FILTER (WHERE regra_id = pg_temp.id('n_km')) = 330
          AND sum(valor_novo) FILTER (WHERE regra_id = pg_temp.id('n_min')) = 5500
     FROM pg_temp.sim(1000, NULL, 'chaveiro', 'pneu', '{base,minimo,por_km}') AS (regra_id uuid, valor_atual bigint, valor_novo bigint, problema text, abrangencia text)),
  'simulação +10%: base nacional 11000, base SP 13200, por km 330, mínimo 5500 (só monetários)');
SELECT pg_temp.confere(
  (SELECT abrangencia LIKE 'nacional: vale para todas as UFs%'
     FROM pg_temp.sim(1000, NULL, 'chaveiro', 'pneu', '{base}') AS (regra_id uuid, valor_atual bigint, valor_novo bigint, problema text, abrangencia text)
    WHERE regra_id = pg_temp.id('n_base')),
  'simulação deixa claro que a regra nacional vale para todas as UFs');
SELECT pg_temp.confere(
  (SELECT count(*) = 1 AND bool_and(regra_id = pg_temp.id('sp_base'))
     FROM pg_temp.sim(1000, NULL, 'chaveiro', 'pneu', '{base}', false) AS (regra_id uuid, valor_atual bigint, valor_novo bigint, problema text, abrangencia text)),
  'sem inclui_nacional, a regra nacional fica fora (só a da UF)');
SELECT pg_temp.confere(pg_temp.foto_igual('antes_sim'), 'simulação não altera nenhuma regra');

-- ======================================================================
-- Solicitar não altera nenhuma regra
-- ======================================================================
SELECT pg_temp.guarda_foto('antes_l1');
INSERT INTO v (k, id) SELECT 'L1', pg_temp.sol('S', 1000, NULL, 'chaveiro', 'pneu', '{base,minimo,por_km}');
SELECT pg_temp.confere(pg_temp.foto_igual('antes_l1'), 'solicitar não altera nenhuma regra');
SELECT pg_temp.confere(
  (SELECT situacao = 'solicitado' AND solicitado_por = pg_temp.u('S') FROM vw_reajuste_taxa WHERE id = pg_temp.id('L1')),
  'lote fica "solicitado", com o solicitante');
SELECT pg_temp.confere(
  (SELECT count(*) = 4 FROM simular_reajuste_taxa(pg_temp.u('S'), pg_temp.id('L1'))),
  'simulação do lote solicitado mostra as 4 regras');

-- ======================================================================
-- Quem aprova; autoaprovação
-- ======================================================================
SELECT pg_temp.espera_erro($$SELECT aprovar_reajuste_taxa(pg_temp.u('S'), pg_temp.id('L1'), '[TESTE]')$$,
  'SC016', 'solicitante sem a permissão não aprova');
SELECT pg_temp.espera_erro($$SELECT aprovar_reajuste_taxa(pg_temp.u('A'), pg_temp.id('L1'), '[TESTE]')$$,
  'SC016', 'conceder_permissao não dá poder de aprovar reajuste');
SELECT pg_temp.espera_erro($$SELECT aprovar_reajuste_taxa(pg_temp.u('P'), pg_temp.id('L1'), '')$$,
  '22023', 'aprovação sem motivo é recusada');

INSERT INTO v (k, id) SELECT 'L2', pg_temp.sol('P', 500, NULL, 'mecanica', 'chaveiro', '{base}');
SELECT pg_temp.espera_erro($$SELECT aprovar_reajuste_taxa(pg_temp.u('P'), pg_temp.id('L2'), '[TESTE]')$$,
  'SC017', 'quem solicitou não aprova o próprio pedido (autoaprovação desligada)');
UPDATE permissao_central SET permite_autoaprovacao = true WHERE codigo = 'aprovar_reajuste_taxa';
SELECT pg_temp.confere(aprovar_reajuste_taxa(pg_temp.u('P'), pg_temp.id('L2'), '[TESTE] exceção') = 1,
  'com a exceção ligada, a autoaprovação passa');
SELECT pg_temp.confere(
  (SELECT autoaprovacao FROM reajuste_taxa_decisao WHERE reajuste_id = pg_temp.id('L2')),
  'decisão marcada como autoaprovação');
UPDATE permissao_central SET permite_autoaprovacao = false WHERE codigo = 'aprovar_reajuste_taxa';

-- ======================================================================
-- Aprovar: encerra as antigas e cria as novas no mesmo instante
-- ======================================================================
SELECT pg_temp.confere(aprovar_reajuste_taxa(pg_temp.u('P'), pg_temp.id('L1'), '[TESTE] aprovado') = 4,
  'aprovação de L1 afeta 4 regras');
INSERT INTO v (k, t) SELECT 'inicio_l1', inicio_efetivo FROM reajuste_taxa_decisao WHERE reajuste_id = pg_temp.id('L1');
SELECT pg_temp.confere(
  (SELECT situacao = 'aprovado' AND regras_afetadas = 4 AND NOT autoaprovacao AND decidido_por = pg_temp.u('P')
          AND inicio_efetivo >= now() AND inicio_efetivo <= clock_timestamp()
     FROM vw_reajuste_taxa WHERE id = pg_temp.id('L1')),
  'decisão: aprovado por P, 4 regras, início no momento da aprovação (relógio do servidor, não o início da transação)');
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
  (SELECT bool_and(fim_vigencia IS NULL AND reajuste_id IS NULL) FROM regra_taxa
    WHERE id IN (pg_temp.id('sp_canc'), pg_temp.id('rj_canc'), pg_temp.id('n_com'), pg_temp.id('n_nc'))),
  'comissão, cancelamentos e não comparecimento (fora do pedido) ficaram intactos');
-- Exclusão de sobreposição: antiga [início antigo, início) e nova [início, …) são contíguas.
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
  pg_temp.valor_vigente('chaveiro', 'pneu', 'SP', 'base', pg_temp.t('inicio_l1') + interval '1 hour') = 13200,
  'instante posterior ao início devolve a regra nova');
SELECT pg_temp.confere(
  pg_temp.valor_vigente('chaveiro', 'pneu', 'RJ', 'base', pg_temp.t('inicio_l1') - interval '1 microsecond') = 10000
  AND pg_temp.valor_vigente('chaveiro', 'pneu', 'RJ', 'base', pg_temp.t('inicio_l1')) = 11000,
  'RJ (sem regra própria) segue a nacional: 10000 antes, 11000 a partir do início');
SELECT pg_temp.confere((SELECT valor = 12000 FROM regra_taxa WHERE id = pg_temp.id('sp_base')),
  'regra antiga continua consultável pelo id');

-- ---------- Imutabilidade da 0010: na antiga, só o fim (já definido pela aprovação) ----------
SELECT pg_temp.espera_erro($$UPDATE regra_taxa SET valor = 1 WHERE id = pg_temp.id('sp_base')$$,
  'SC012', 'regra antiga: valor não muda');
SELECT pg_temp.espera_erro($$UPDATE regra_taxa SET observacao = 'x' WHERE id = pg_temp.id('sp_base')$$,
  'SC012', 'regra antiga: observação não muda');
SELECT pg_temp.espera_erro($$UPDATE regra_taxa SET inicio_vigencia = inicio_vigencia - interval '1 day' WHERE id = pg_temp.id('sp_base')$$,
  'SC012', 'regra antiga: início não muda');
SELECT pg_temp.espera_erro($$UPDATE regra_taxa SET reajuste_id = pg_temp.id('L1'), regra_origem_id = pg_temp.id('n_base') WHERE id = pg_temp.id('sp_base')$$,
  'SC012', 'regra antiga: vínculo com lote não muda');
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
  EXISTS (SELECT 1 FROM auditoria WHERE entidade = 'reajuste_taxa' AND entidade_id = pg_temp.id('L1')
             AND ator_usuario_id = pg_temp.u('S'))
  AND EXISTS (SELECT 1 FROM auditoria WHERE entidade = 'reajuste_taxa_decisao' AND ator_usuario_id = pg_temp.u('P')
                 AND depois ->> 'reajuste_id' = pg_temp.id('L1')::text AND depois ->> 'situacao' = 'aprovado'),
  'solicitação (ator S) e aprovação (ator P) na auditoria');
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
INSERT INTO v (k, id) SELECT 'L3', pg_temp.sol('S', 200, NULL, 'chaveiro', 'pneu', '{base}');
SELECT pg_temp.guarda_foto('antes_l3');
SELECT pg_temp.espera_erro($$SELECT rejeitar_reajuste_taxa(pg_temp.u('S'), pg_temp.id('L3'), '[TESTE]')$$,
  'SC016', 'sem a permissão, não rejeita');
SELECT rejeitar_reajuste_taxa(pg_temp.u('Q'), pg_temp.id('L3'), '[TESTE] índice errado');
SELECT pg_temp.confere(pg_temp.foto_igual('antes_l3'), 'rejeitar não altera nenhuma regra');
SELECT pg_temp.confere((SELECT situacao = 'rejeitado' AND decidido_por = pg_temp.u('Q') FROM vw_reajuste_taxa WHERE id = pg_temp.id('L3')),
  'lote rejeitado por Q');
SELECT pg_temp.espera_erro($$SELECT aprovar_reajuste_taxa(pg_temp.u('P'), pg_temp.id('L3'), '[TESTE]')$$,
  'SC020', 'lote rejeitado não é aprovado');

INSERT INTO v (k, id) SELECT 'L4', pg_temp.sol('S', -300, NULL, 'chaveiro', 'pneu', '{base}');
SELECT pg_temp.guarda_foto('antes_l4');
SELECT pg_temp.espera_erro($$SELECT cancelar_reajuste_taxa(pg_temp.u('A'), pg_temp.id('L4'), '[TESTE]')$$,
  'SC016', 'quem não é o solicitante nem aprovador não cancela');
SELECT cancelar_reajuste_taxa(pg_temp.u('S'), pg_temp.id('L4'), '[TESTE] desisti');
SELECT pg_temp.confere(pg_temp.foto_igual('antes_l4'), 'cancelar não altera nenhuma regra');
SELECT pg_temp.confere((SELECT situacao = 'cancelado' AND decidido_por = pg_temp.u('S') FROM vw_reajuste_taxa WHERE id = pg_temp.id('L4')),
  'lote cancelado pelo próprio solicitante');

-- ======================================================================
-- "A definir" no escopo: recusa (SC013) sem alterar NADA
-- ======================================================================
INSERT INTO v (k, id) SELECT 'L5', pg_temp.sol('S', 1000, NULL, 'chaveiro', 'bateria', '{base}', false);
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
SELECT pg_temp.espera_erro($$SELECT pg_temp.sol('S', 1000, NULL, 'chaveiro', 'bateria', '{base}', false)$$,
  'SC013', 'a solicitação já recusa escopo com "a definir"');

-- ======================================================================
-- Resultado inválido e "nada a alterar" (SC022)
-- ======================================================================
SELECT pg_temp.espera_erro($$SELECT pg_temp.sol('S', NULL, -1, 'chaveiro', 'pneu', '{nao_comparecimento}')$$,
  'SC022', 'reajuste que zeraria um valor maior que zero é recusado');
SELECT pg_temp.espera_erro($$SELECT pg_temp.sol('S', NULL, -2, 'chaveiro', 'pneu', '{nao_comparecimento}')$$,
  'SC022', 'reajuste que deixaria valor negativo é recusado');
SELECT pg_temp.espera_erro($$SELECT pg_temp.sol('S', 500, NULL, 'mecanica', 'chaveiro', '{comissao_plataforma}', true, true)$$,
  'SC022', 'comissão acima de 10000 pb (9600 + 5% = 10080) é recusada');
SELECT pg_temp.confere(
  (SELECT problema = 'sem_alteracao' AND valor_novo = 3
     FROM pg_temp.sim(100, NULL, 'mecanica', 'chaveiro', '{minimo}') AS (regra_id uuid, valor_atual bigint, valor_novo bigint, problema text, abrangencia text)),
  'simulação marca "sem_alteracao" (3 + 1% = 3,03, arredonda para 3)');
SELECT pg_temp.espera_erro($$SELECT pg_temp.sol('S', 100, NULL, 'mecanica', 'chaveiro', '{minimo}')$$,
  'SC022', 'nada a alterar: nenhuma regra muda de valor');

-- Valor igual entra como nova versão quando outra regra do lote muda.
INSERT INTO v (k, id) SELECT 'L7', pg_temp.sol('S', 100, NULL, 'mecanica', 'chaveiro', '{base,minimo}');
SELECT pg_temp.confere(aprovar_reajuste_taxa(pg_temp.u('Q'), pg_temp.id('L7'), '[TESTE]') = 2,
  'lote misto: base muda e mínimo fica igual; 2 regras ganham nova versão');
SELECT pg_temp.confere(
  (SELECT array_agg(valor ORDER BY componente) = '{4242,3}' FROM regra_taxa WHERE reajuste_id = pg_temp.id('L7')),
  'base 4200 + 1% = 4242; mínimo 3 continua 3, como nova versão');

-- ======================================================================
-- Pontos-base só com pedido explícito; 0,5 sobe no fluxo real; reajuste negativo
-- ======================================================================
INSERT INTO v (k, id) SELECT 'L8', pg_temp.sol('S', 500, NULL, 'chaveiro', 'pneu', '{cancelamento,comissao_plataforma}', true, true);
SELECT pg_temp.confere(aprovar_reajuste_taxa(pg_temp.u('Q'), pg_temp.id('L8'), '[TESTE]') = 3,
  'com inclui_pontos_base: cancelamento SP (centavos), cancelamento RJ (pb) e comissão');
SELECT pg_temp.confere(
  (SELECT valor = 1733 FROM regra_taxa WHERE regra_origem_id = pg_temp.id('sp_canc'))
  AND (SELECT valor = 1050 FROM regra_taxa WHERE regra_origem_id = pg_temp.id('rj_canc'))
  AND (SELECT valor = 1575 FROM regra_taxa WHERE regra_origem_id = pg_temp.id('n_com')),
  'cancelamento SP 1650 + 5% = 1732,5 vira 1733; RJ 1000 pb vira 1050; comissão 1500 vira 1575');

INSERT INTO v (k, id) SELECT 'L9', pg_temp.sol('S', -1000, NULL, 'chaveiro', 'pneu', '{minimo}');
SELECT pg_temp.confere(aprovar_reajuste_taxa(pg_temp.u('P'), pg_temp.id('L9'), '[TESTE] deflação') = 1,
  'reajuste negativo é aprovado');
SELECT pg_temp.confere(
  (SELECT valor = 4950 FROM regra_taxa WHERE reajuste_id = pg_temp.id('L9')),
  'mínimo 5500 - 10% = 4950');

-- ======================================================================
-- Início informado na aprovação: futuro aceito; passado recusado
-- ======================================================================
INSERT INTO v (k, id) SELECT 'L10', pg_temp.sol('S', 1000, NULL, 'chaveiro', 'pneu', '{por_km}');
SELECT pg_temp.guarda_foto('antes_l10');
SELECT pg_temp.espera_erro($$SELECT aprovar_reajuste_taxa(pg_temp.u('P'), pg_temp.id('L10'), '[TESTE]', now() - interval '1 second')$$,
  'SC012', 'aprovação com início no passado é recusada');
SELECT pg_temp.confere(pg_temp.foto_igual('antes_l10'), 'início no passado não alterou nada');
INSERT INTO v (k, t) VALUES ('inicio_l10', clock_timestamp() + interval '1 day');
SELECT pg_temp.confere(aprovar_reajuste_taxa(pg_temp.u('P'), pg_temp.id('L10'), '[TESTE] agendado', pg_temp.t('inicio_l10')) = 1,
  'aprovação com início futuro');
SELECT pg_temp.confere(
  pg_temp.valor_vigente('chaveiro', 'pneu', NULL, 'por_km', clock_timestamp()) = 330
  AND pg_temp.valor_vigente('chaveiro', 'pneu', NULL, 'por_km', pg_temp.t('inicio_l10')) = 363,
  'até o início futuro vale 330; a partir dele, 363');

-- ======================================================================
-- Regra futura agendada ou vigente que termina antes do início (SC021)
-- ======================================================================
SELECT pg_temp.espera_erro($$SELECT pg_temp.sol('S', 1000, NULL, 'chaveiro', 'pneu', '{por_km}')$$,
  'SC021', 'regra futura agendada no escopo (por km a partir de amanhã) recusa');
SELECT pg_temp.regra('m_base_fim', 'mecanica', 'chaveiro', 'SP', 'base', 'centavos', 5000);
UPDATE regra_taxa SET fim_vigencia = now() + interval '5 days' WHERE id = pg_temp.id('m_base_fim');
SELECT pg_temp.espera_erro($$
  SELECT pg_temp.sol('S', 1000, NULL, 'mecanica', 'chaveiro', '{base}', true, false, NULL, now() + interval '10 days')$$,
  'SC021', 'regra vigente que termina antes do início recusa');
