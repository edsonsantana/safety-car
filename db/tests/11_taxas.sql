-- 11 — Regras de taxa (0010): unidades, vigência sem sobreposição, imutabilidade e regra vigente.
-- Valores FICTÍCIOS. Escopo chaveiro/pneu: fora da carga inicial da 0012, para não colidir com ela.
-- now() é fixo dentro da transação do teste.

CREATE FUNCTION pg_temp.taxa(p_uf text, p_componente text, p_unidade text, p_valor bigint,
                             p_inicio timestamptz DEFAULT now(), p_situacao text DEFAULT 'definido')
RETURNS uuid LANGUAGE sql AS $f$
  INSERT INTO regra_taxa (tipo_parceiro_codigo, servico_codigo, uf, componente, unidade, valor,
                          situacao, inicio_vigencia)
  VALUES ('chaveiro', 'pneu', p_uf, p_componente, p_unidade, p_valor, p_situacao, p_inicio)
  RETURNING id
$f$;

CREATE TEMP TABLE r (rotulo text PRIMARY KEY, id uuid);

-- ---------- Tipos: inteiros, nunca float ----------
SELECT pg_temp.confere(
  (SELECT data_type = 'bigint' FROM information_schema.columns
    WHERE table_name = 'regra_taxa' AND column_name = 'valor'),
  'valor da taxa é inteiro (bigint), sem float nem numeric');
SELECT pg_temp.confere(
  NOT EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_name = 'regra_taxa' AND data_type IN ('real','double precision','numeric','money')),
  'regra_taxa não tem coluna float, numeric ou money');

-- ---------- Unidade fixa por componente ----------
SELECT pg_temp.espera_erro($$SELECT pg_temp.taxa(NULL, 'base', 'pontos_base', 100)$$,
  '23514', 'base em pontos-base é rejeitada (só centavos)');
SELECT pg_temp.espera_erro($$SELECT pg_temp.taxa(NULL, 'minimo', 'centavos_por_km', 100)$$,
  '23514', 'mínimo em centavos por km é rejeitado');
SELECT pg_temp.espera_erro($$SELECT pg_temp.taxa(NULL, 'nao_comparecimento', 'pontos_base', 100)$$,
  '23514', 'não comparecimento em pontos-base é rejeitado');
SELECT pg_temp.espera_erro($$SELECT pg_temp.taxa(NULL, 'por_km', 'centavos', 100)$$,
  '23514', 'por km em centavos (sem "por km") é rejeitado');
SELECT pg_temp.espera_erro($$SELECT pg_temp.taxa(NULL, 'comissao_plataforma', 'centavos', 100)$$,
  '23514', 'comissão em centavos é rejeitada (só pontos-base)');
SELECT pg_temp.espera_erro($$SELECT pg_temp.taxa(NULL, 'comissao_plataforma', 'pontos_base', 10001)$$,
  '23514', 'pontos-base acima de 10000 (100%) é rejeitado');
SELECT pg_temp.espera_erro($$SELECT pg_temp.taxa(NULL, 'base', 'centavos', -1)$$,
  '23514', 'valor negativo é rejeitado');
SELECT pg_temp.espera_erro($$SELECT pg_temp.taxa(NULL, 'base', 'centavos', 100, now(), 'a_definir')$$,
  '23514', '"a definir" com valor diferente de zero é rejeitado');
SELECT pg_temp.aceita($$SELECT pg_temp.taxa('SP', 'cancelamento', 'centavos', 2500)$$,
  'cancelamento em centavos é aceito');
SELECT pg_temp.aceita($$SELECT pg_temp.taxa('RJ', 'cancelamento', 'pontos_base', 1000)$$,
  'cancelamento em pontos-base é aceito');
SELECT pg_temp.aceita($$SELECT pg_temp.taxa(NULL, 'comissao_plataforma', 'pontos_base', 1500)$$,
  'comissão em pontos-base é aceita');

-- ---------- base_distancia ----------
INSERT INTO r SELECT 'km', pg_temp.taxa(NULL, 'por_km', 'centavos_por_km', 450);
SELECT pg_temp.confere((SELECT base_distancia = 'linha_reta' FROM regra_taxa WHERE id = (SELECT id FROM r WHERE rotulo = 'km')),
  'por km sem base_distancia recebe linha_reta (padrão)');
SELECT pg_temp.aceita($$
  INSERT INTO regra_taxa (tipo_parceiro_codigo, servico_codigo, uf, componente, unidade, valor, situacao, base_distancia)
  VALUES ('chaveiro', 'pneu', 'SP', 'por_km', 'centavos_por_km', 500, 'definido', 'provedor_externo')$$,
  'por km com base provedor_externo é aceito');
SELECT pg_temp.espera_erro($$
  INSERT INTO regra_taxa (tipo_parceiro_codigo, servico_codigo, uf, componente, unidade, valor, situacao, base_distancia)
  VALUES ('chaveiro', 'pneu', 'MG', 'por_km', 'centavos_por_km', 500, 'definido', 'waze')$$,
  '23514', 'base_distancia fora da lista é rejeitada');
SELECT pg_temp.espera_erro($$
  INSERT INTO regra_taxa (tipo_parceiro_codigo, servico_codigo, uf, componente, unidade, valor, situacao, base_distancia)
  VALUES ('chaveiro', 'pneu', 'MG', 'base', 'centavos', 500, 'definido', 'linha_reta')$$,
  '23514', 'base_distancia em componente que não é por km é rejeitada');

-- ---------- Vigência sem sobreposição ----------
INSERT INTO r SELECT 'nac', pg_temp.taxa(NULL, 'base', 'centavos', 15000);
INSERT INTO r SELECT 'sp',  pg_temp.taxa('SP', 'base', 'centavos', 18000);
SELECT pg_temp.espera_erro($$SELECT pg_temp.taxa(NULL, 'base', 'centavos', 16000)$$,
  '23P01', 'segunda regra nacional sobreposta no mesmo escopo é rejeitada');
SELECT pg_temp.espera_erro($$SELECT pg_temp.taxa('SP', 'base', 'centavos', 19000, now() + interval '30 days')$$,
  '23P01', 'regra futura sobreposta a uma vigente sem fim é rejeitada');
SELECT pg_temp.aceita($$
  INSERT INTO regra_taxa (tipo_parceiro_codigo, servico_codigo, uf, componente, unidade, valor, situacao)
  VALUES ('mecanica', 'pneu', 'SP', 'base', 'centavos', 18000, 'definido')$$,
  'mesmo serviço, UF e componente para outro tipo de parceiro não conflita');

-- Mudança de valor = encerrar a vigente e criar a próxima, sem sobreposição.
SELECT pg_temp.aceita($$
  UPDATE regra_taxa SET fim_vigencia = now() + interval '30 days' WHERE id = (SELECT id FROM r WHERE rotulo = 'sp')$$,
  'regra vigente aceita a definição do fim de vigência');
SELECT pg_temp.espera_erro($$SELECT pg_temp.taxa('SP', 'base', 'centavos', 19000, now() + interval '29 days')$$,
  '23P01', 'nova regra começando antes do fim da anterior é rejeitada');
INSERT INTO r SELECT 'sp2', pg_temp.taxa('SP', 'base', 'centavos', 19000, now() + interval '30 days');
SELECT pg_temp.confere((SELECT id FROM r WHERE rotulo = 'sp2') IS NOT NULL,
  'nova regra começando exatamente no fim da anterior é aceita (intervalo [início, fim))');

-- ---------- Imutabilidade ----------
SELECT pg_temp.espera_erro($$UPDATE regra_taxa SET valor = 1 WHERE id = (SELECT id FROM r WHERE rotulo = 'nac')$$,
  'SC012', 'edição do valor de regra vigente é recusada');
SELECT pg_temp.espera_erro($$UPDATE regra_taxa SET situacao = 'a_definir', valor = 0 WHERE id = (SELECT id FROM r WHERE rotulo = 'nac')$$,
  'SC012', 'regra vigente não volta para "a definir"');
SELECT pg_temp.espera_erro($$UPDATE regra_taxa SET inicio_vigencia = now() + interval '1 day' WHERE id = (SELECT id FROM r WHERE rotulo = 'nac')$$,
  'SC012', 'edição do início de vigência é recusada');
SELECT pg_temp.espera_erro($$UPDATE regra_taxa SET base_distancia = 'rodoviaria_snv' WHERE id = (SELECT id FROM r WHERE rotulo = 'km')$$,
  'SC012', 'troca da base de distância de regra vigente é recusada');
SELECT pg_temp.espera_erro($$DELETE FROM regra_taxa WHERE id = (SELECT id FROM r WHERE rotulo = 'nac')$$,
  'SC012', 'exclusão de regra é recusada');
SELECT pg_temp.espera_erro($$UPDATE regra_taxa SET fim_vigencia = now() - interval '1 second' WHERE id = (SELECT id FROM r WHERE rotulo = 'nac')$$,
  'SC012', 'fim de vigência retroativo é recusado');
SELECT pg_temp.espera_erro($$UPDATE regra_taxa SET fim_vigencia = NULL WHERE id = (SELECT id FROM r WHERE rotulo = 'sp')$$,
  'SC012', 'fim de vigência definido não pode ser removido');
SELECT pg_temp.espera_erro($$SELECT pg_temp.taxa('BA', 'base', 'centavos', 100, now() - interval '1 day')$$,
  'SC012', 'regra com início no passado é recusada');

-- Regra encerrada agora não muda mais.
INSERT INTO r SELECT 'ba', pg_temp.taxa('BA', 'base', 'centavos', 100);
UPDATE regra_taxa SET fim_vigencia = now() WHERE id = (SELECT id FROM r WHERE rotulo = 'ba');
SELECT pg_temp.espera_erro($$UPDATE regra_taxa SET fim_vigencia = now() + interval '1 day' WHERE id = (SELECT id FROM r WHERE rotulo = 'ba')$$,
  'SC012', 'regra já encerrada não pode ser reaberta');

-- Regra futura pode ser anulada (fim = início).
INSERT INTO r SELECT 'pe', pg_temp.taxa('PE', 'base', 'centavos', 100, now() + interval '10 days');
SELECT pg_temp.aceita($$
  UPDATE regra_taxa SET fim_vigencia = inicio_vigencia WHERE id = (SELECT id FROM r WHERE rotulo = 'pe')$$,
  'regra futura é anulada com fim = início');

-- ---------- Regra vigente ----------
SELECT pg_temp.confere((regra_taxa_vigente('chaveiro', 'pneu', 'SP', 'base')).valor = 18000,
  'em SP vale a regra da UF');
SELECT pg_temp.confere((regra_taxa_vigente('chaveiro', 'pneu', 'SP', 'base', now() + interval '31 days')).valor = 19000,
  'em SP, depois do fim da regra anterior, vale a nova');
SELECT pg_temp.confere((regra_taxa_vigente('chaveiro', 'pneu', 'RJ', 'base')).valor = 15000,
  'no RJ (sem regra da UF) vale a nacional');
SELECT pg_temp.confere((regra_taxa_vigente('chaveiro', 'pneu', 'PE', 'base', now() + interval '11 days')).valor = 15000,
  'regra anulada nunca vigora (vale a nacional)');
SELECT pg_temp.confere((regra_taxa_vigente('chaveiro', 'pneu', NULL, 'por_km')).base_distancia = 'linha_reta',
  'regra por km vigente informa a base de distância');

SELECT pg_temp.aceita($$SELECT pg_temp.taxa('MG', 'base', 'centavos', 0, now(), 'a_definir')$$,
  'regra de UF "a definir" (valor zerado e marcado)');
SELECT pg_temp.espera_erro($$SELECT regra_taxa_vigente('chaveiro', 'pneu', 'MG', 'base')$$,
  'SC013', 'regra da UF "a definir" é recusada (não cai na nacional nem vira zero)');
SELECT pg_temp.espera_erro($$SELECT regra_taxa_vigente('chaveiro', 'pneu', 'SP', 'minimo')$$,
  'SC013', 'componente sem regra é recusado');
SELECT pg_temp.espera_erro($$SELECT regra_taxa_vigente('chaveiro', 'pneu', 'SP', 'base', now() - interval '1 day')$$,
  'SC013', 'instante anterior a qualquer regra é recusado');
SELECT pg_temp.espera_erro($$SELECT regra_taxa_vigente('chaveiro', 'pneu', 'SP', 'gorjeta')$$,
  '22023', 'componente inválido na consulta');

-- ---------- Auditoria ----------
SELECT pg_temp.confere(
  EXISTS (SELECT 1 FROM auditoria WHERE entidade = 'regra_taxa' AND acao = 'parametrizacao_update'
             AND entidade_id = (SELECT id FROM r WHERE rotulo = 'sp')
             AND antes ->> 'fim_vigencia' IS NULL AND depois ->> 'fim_vigencia' IS NOT NULL),
  'encerramento de vigência fica na auditoria (antes e depois)');
SELECT pg_temp.espera_erro($$TRUNCATE regra_taxa$$, 'SC010', 'TRUNCATE em regra_taxa é bloqueado');
