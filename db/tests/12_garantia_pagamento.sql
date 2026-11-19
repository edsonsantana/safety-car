-- 12 — Garantia e provedores de pagamento (0011). Valores FICTÍCIOS.
-- Encerra antes a eventual carga "a definir" da 0012 nos escopos usados, para não colidir com ela.

UPDATE politica_garantia SET fim_vigencia = now()
 WHERE servico_codigo IN ('pneu','bateria') AND fim_vigencia IS NULL;

CREATE FUNCTION pg_temp.garantia(p_servico text, p_nivel int, p_modalidade text, p_calculo text,
                                 p_valor bigint, p_pb int, p_situacao text DEFAULT 'definido',
                                 p_inicio timestamptz DEFAULT now())
RETURNS uuid LANGUAGE sql AS $f$
  INSERT INTO politica_garantia (servico_codigo, nivel_verificacao, modalidade, calculo,
                                 valor_centavos, percentual_bp, situacao, inicio_vigencia)
  VALUES (p_servico, p_nivel, p_modalidade, p_calculo, p_valor, p_pb, p_situacao, p_inicio)
  RETURNING id
$f$;
CREATE TEMP TABLE g (rotulo text PRIMARY KEY, id uuid);

-- ---------- Nenhum segredo no banco ----------
SELECT pg_temp.confere(
  NOT EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_name IN ('provedor_pagamento','politica_garantia')
                 AND column_name ~* '(chave|segredo|secret|token|senha|password|key|credencial|api|webhook|callback|certificado)'),
  'provedor e garantia não têm coluna de chave, segredo, token, senha, credencial ou callback');
SELECT pg_temp.confere(
  NOT EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_name = 'politica_garantia'
                 AND data_type IN ('real','double precision','numeric','money')),
  'garantia sem float, numeric ou money (centavos e pontos-base inteiros)');

-- ---------- Cálculo: exatamente um valor ----------
SELECT pg_temp.espera_erro($$SELECT pg_temp.garantia('pneu', 1, 'pix_pre_pago', 'valor_fixo', NULL, 1000)$$,
  '23514', 'valor fixo sem centavos (com percentual) é rejeitado');
SELECT pg_temp.espera_erro($$SELECT pg_temp.garantia('pneu', 1, 'pix_pre_pago', 'percentual', 5000, 1000)$$,
  '23514', 'percentual com centavos junto é rejeitado');
SELECT pg_temp.espera_erro($$SELECT pg_temp.garantia('pneu', 1, 'pix_pre_pago', 'percentual', NULL, 10001)$$,
  '23514', 'percentual acima de 100% é rejeitado');
SELECT pg_temp.espera_erro($$SELECT pg_temp.garantia('pneu', 1, 'boleto', 'valor_fixo', 5000, NULL)$$,
  '23514', 'modalidade fora da lista é rejeitada');
SELECT pg_temp.espera_erro($$SELECT pg_temp.garantia('pneu', 1, 'pix_pre_pago', 'valor_fixo', 5000, NULL, 'a_definir')$$,
  '23514', '"a definir" com valor é rejeitado');

INSERT INTO g SELECT 'fixo', pg_temp.garantia('pneu', 1, 'pre_autorizacao_cartao', 'valor_fixo', 20000, NULL);
INSERT INTO g SELECT 'pct',  pg_temp.garantia('pneu', 2, 'pre_autorizacao_cartao', 'percentual', NULL, 5000);
INSERT INTO g SELECT 'pix',  pg_temp.garantia('pneu', 1, 'pix_pre_pago', 'valor_fixo', 15000, NULL);
SELECT pg_temp.confere((SELECT count(*) = 3 FROM g WHERE id IS NOT NULL),
  'garantias de valor fixo e percentual, cartão e Pix, aceitas');

-- ---------- Vigência ----------
SELECT pg_temp.espera_erro($$SELECT pg_temp.garantia('pneu', 1, 'pre_autorizacao_cartao', 'valor_fixo', 25000, NULL)$$,
  '23P01', 'garantia sobreposta no mesmo serviço, nível e modalidade é rejeitada');
SELECT pg_temp.aceita($$SELECT pg_temp.garantia('pneu', 3, 'pre_autorizacao_cartao', 'valor_fixo', 10000, NULL)$$,
  'outro nível no mesmo serviço e modalidade não conflita');
SELECT pg_temp.espera_erro($$UPDATE politica_garantia SET valor_centavos = 1 WHERE id = (SELECT id FROM g WHERE rotulo = 'fixo')$$,
  'SC012', 'edição do valor de garantia vigente é recusada');
SELECT pg_temp.espera_erro($$UPDATE politica_garantia SET calculo = 'percentual', valor_centavos = NULL, percentual_bp = 100
                               WHERE id = (SELECT id FROM g WHERE rotulo = 'fixo')$$,
  'SC012', 'troca do tipo de cálculo de garantia vigente é recusada');
SELECT pg_temp.espera_erro($$DELETE FROM politica_garantia WHERE id = (SELECT id FROM g WHERE rotulo = 'fixo')$$,
  'SC012', 'exclusão de garantia é recusada');
SELECT pg_temp.aceita($$UPDATE politica_garantia SET fim_vigencia = now() + interval '7 days'
                         WHERE id = (SELECT id FROM g WHERE rotulo = 'fixo')$$,
  'fim de vigência da garantia pode ser definido');
SELECT pg_temp.aceita($$SELECT pg_temp.garantia('pneu', 1, 'pre_autorizacao_cartao', 'valor_fixo', 25000, NULL,
                                                'definido', now() + interval '7 days')$$,
  'nova garantia a partir do fim da anterior');

-- ---------- Política vigente ----------
SELECT pg_temp.confere((politica_garantia_vigente('pneu', 1, 'pre_autorizacao_cartao')).valor_centavos = 20000,
  'política vigente hoje (valor fixo)');
SELECT pg_temp.confere((politica_garantia_vigente('pneu', 1, 'pre_autorizacao_cartao', now() + interval '8 days')).valor_centavos = 25000,
  'política vigente depois da troca');
SELECT pg_temp.confere((politica_garantia_vigente('pneu', 2, 'pre_autorizacao_cartao')).percentual_bp = 5000,
  'política percentual (pontos-base)');
SELECT pg_temp.aceita($$SELECT pg_temp.garantia('bateria', 1, 'pix_pre_pago', 'valor_fixo', 0, NULL, 'a_definir')$$,
  'garantia "a definir" (zerada e marcada)');
SELECT pg_temp.espera_erro($$SELECT politica_garantia_vigente('bateria', 1, 'pix_pre_pago')$$,
  'SC013', 'garantia "a definir" é recusada (não vira garantia zero)');
SELECT pg_temp.espera_erro($$SELECT politica_garantia_vigente('bateria', 2, 'pix_pre_pago')$$,
  'SC013', 'sem política vigente é recusado');
SELECT pg_temp.espera_erro($$SELECT politica_garantia_vigente('pneu', 4, 'pix_pre_pago')$$,
  '22023', 'nível inexistente na consulta');

-- ---------- Provedores ----------
SELECT pg_temp.aceita($$
  INSERT INTO provedor_pagamento (codigo, nome, ambiente, suporta_pre_autorizacao, suporta_pix, suporta_split)
  VALUES ('psp_ficticio', '[TESTE] PSP fictício', 'sandbox', true, true, false)$$,
  'provedor com capacidades e ambiente');
SELECT pg_temp.confere((SELECT NOT ativo FROM provedor_pagamento WHERE codigo = 'psp_ficticio'),
  'provedor nasce inativo (ativação explícita)');
SELECT pg_temp.aceita($$
  INSERT INTO provedor_pagamento (codigo, nome, ambiente) VALUES ('psp_ficticio', '[TESTE] PSP fictício', 'producao')$$,
  'mesmo provedor em outro ambiente');
SELECT pg_temp.espera_erro($$
  INSERT INTO provedor_pagamento (codigo, nome, ambiente) VALUES ('psp_ficticio', 'x', 'sandbox')$$,
  '23505', 'mesmo provedor duas vezes no mesmo ambiente é rejeitado');
SELECT pg_temp.espera_erro($$
  INSERT INTO provedor_pagamento (codigo, nome, ambiente) VALUES ('psp_x', 'x', 'homologacao')$$,
  '23514', 'ambiente fora da lista é rejeitado');
UPDATE provedor_pagamento SET ativo = true WHERE codigo = 'psp_ficticio' AND ambiente = 'sandbox';
SELECT pg_temp.confere(
  EXISTS (SELECT 1 FROM auditoria WHERE entidade = 'provedor_pagamento' AND acao = 'parametrizacao_update'
             AND (antes ->> 'ativo')::boolean = false AND (depois ->> 'ativo')::boolean = true),
  'ativação de provedor fica na auditoria');
SELECT pg_temp.espera_erro($$TRUNCATE provedor_pagamento$$, 'SC010', 'TRUNCATE em provedor_pagamento é bloqueado');
