-- 13 — Parametrização vista pelo app (0009 a 0012). Este arquivo roda CONECTADO como safetycar_app.

SELECT pg_temp.confere(current_user = 'safetycar_app', 'teste conectado como safetycar_app');

-- ---------- Leitura ----------
SELECT pg_temp.aceita($$
  SELECT (SELECT count(*) FROM nivel_verificacao), (SELECT count(*) FROM requisito_verificacao),
         (SELECT count(*) FROM nivel_requisito),   (SELECT count(*) FROM servico_nivel_minimo),
         (SELECT count(*) FROM regra_taxa),        (SELECT count(*) FROM politica_garantia),
         (SELECT count(*) FROM provedor_pagamento)$$,
  'app lê todas as tabelas de parametrização');

-- ---------- Sem escrita ----------
SELECT pg_temp.espera_erro($$INSERT INTO nivel_verificacao (nivel, nome) VALUES (3, 'x')$$,
  '42501', 'app não insere nível');
SELECT pg_temp.espera_erro($$UPDATE requisito_verificacao SET nome = 'x'$$,
  '42501', 'app não altera requisito');
SELECT pg_temp.espera_erro($$UPDATE nivel_requisito SET situacao = 'definido'$$,
  '42501', 'app não altera requisitos por nível');
SELECT pg_temp.espera_erro($$UPDATE servico_nivel_minimo SET nivel_minimo = 1, situacao = 'definido'$$,
  '42501', 'app não define nível mínimo');
SELECT pg_temp.espera_erro($$DELETE FROM servico_nivel_minimo$$,
  '42501', 'app não apaga nível mínimo');
SELECT pg_temp.espera_erro($$
  INSERT INTO regra_taxa (tipo_parceiro_codigo, servico_codigo, componente, unidade, valor, situacao)
  VALUES ('guincho', 'guincho_leve', 'base', 'centavos', 1, 'definido')$$,
  '42501', 'app não cria regra de taxa');
SELECT pg_temp.espera_erro($$UPDATE regra_taxa SET fim_vigencia = now() + interval '1 day'$$,
  '42501', 'app não encerra regra de taxa');
SELECT pg_temp.espera_erro($$DELETE FROM regra_taxa$$,
  '42501', 'app não apaga regra de taxa');
SELECT pg_temp.espera_erro($$UPDATE politica_garantia SET fim_vigencia = now() + interval '1 day'$$,
  '42501', 'app não altera política de garantia');
SELECT pg_temp.espera_erro($$
  INSERT INTO provedor_pagamento (codigo, nome, ambiente) VALUES ('psp_app', 'x', 'sandbox')$$,
  '42501', 'app não cadastra provedor de pagamento');
SELECT pg_temp.espera_erro($$TRUNCATE regra_taxa$$,
  '42501', 'app não trunca parametrização');

-- ---------- Carga inicial: tudo "a definir", e as consultas recusam ----------
SELECT pg_temp.confere(
  NOT EXISTS (SELECT 1 FROM nivel_requisito      WHERE situacao <> 'a_definir')
  AND NOT EXISTS (SELECT 1 FROM servico_nivel_minimo WHERE situacao <> 'a_definir')
  AND NOT EXISTS (SELECT 1 FROM regra_taxa           WHERE situacao <> 'a_definir' OR valor <> 0)
  AND NOT EXISTS (SELECT 1 FROM politica_garantia    WHERE situacao <> 'a_definir'
                                                        OR coalesce(valor_centavos, 0) + coalesce(percentual_bp, 0) <> 0),
  'carga inicial inteira está "a definir", com valores zerados');
SELECT pg_temp.confere((SELECT count(*) = 0 FROM provedor_pagamento),
  'nenhum provedor de pagamento carregado (processador não escolhido)');
SELECT pg_temp.confere(
  (SELECT count(*) = 12 AND bool_and(observacao LIKE 'PROPOSTA%') FROM nivel_requisito),
  'requisitos por nível carregados como PROPOSTA (5 do tomador, 7 do parceiro)');
SELECT pg_temp.confere(
  NOT EXISTS (SELECT 1 FROM nivel_requisito WHERE perfil = 'tomador' AND requisito_codigo = 'mfa'),
  '2FA não é requisito do tomador');
SELECT pg_temp.confere(
  (SELECT count(*) = 14 FROM servico_nivel_minimo),
  'nível mínimo: 7 serviços x 2 perfis');
SELECT pg_temp.confere(
  (SELECT count(*) = 42 AND count(DISTINCT (tipo_parceiro_codigo, servico_codigo)) = 7 AND bool_and(uf IS NULL)
     FROM regra_taxa),
  'taxas: 7 combinações de tipo e serviço x 6 componentes, nacionais');
SELECT pg_temp.confere(
  (SELECT base_distancia = 'linha_reta' FROM regra_taxa
    WHERE tipo_parceiro_codigo = 'guincho' AND servico_codigo = 'guincho_leve' AND componente = 'por_km'),
  'carga do por km com base_distancia linha_reta');
SELECT pg_temp.confere(
  (SELECT count(*) = 42 FROM politica_garantia),
  'garantia: 7 serviços x 3 níveis x 2 modalidades');

SELECT pg_temp.espera_erro($$SELECT nivel_minimo_servico('guincho_leve', 'tomador')$$,
  'SC013', 'app: nível mínimo da carga é recusado (a definir)');
SELECT pg_temp.espera_erro($$SELECT cumpre_nivel_minimo('tomador', 3, 'guincho_leve')$$,
  'SC013', 'app: nem nível 3 "cumpre" um mínimo a definir');
SELECT pg_temp.espera_erro($$SELECT regra_taxa_vigente('guincho', 'guincho_leve', 'SP', 'base')$$,
  'SC013', 'app: taxa da carga é recusada (a definir, nunca zero)');
SELECT pg_temp.espera_erro($$SELECT regra_taxa_vigente('guincho', 'guincho_leve', NULL, 'comissao_plataforma')$$,
  'SC013', 'app: comissão da carga é recusada');
SELECT pg_temp.espera_erro($$SELECT politica_garantia_vigente('guincho_leve', 1, 'pix_pre_pago')$$,
  'SC013', 'app: garantia da carga é recusada');

-- ---------- Auditoria ----------
-- Desde a 0020 o app não lê a auditoria (só insere). A carga auditada e o papel_bd das linhas
-- gravadas pelo app são conferidos em 24_endurecimento_app.sql (como postgres, no fim).
SELECT pg_temp.espera_erro($$SELECT count(*) FROM auditoria$$,
  '42501', 'app não lê a auditoria (0020)');

-- ---------- Histórico de nível pelo app ----------
INSERT INTO usuario (id, keycloak_sub, email, perfil) VALUES
  ('00000000-0000-4000-8000-000000000d01', gen_random_uuid(), 'app-niv@exemplo.invalid', 'tomador');
INSERT INTO tomador (usuario_id, nome_completo, cpf_cifrado, cpf_hash) VALUES
  ('00000000-0000-4000-8000-000000000d01', '[TESTE] Tomador via app', '\x01', pg_temp.hmac_teste('39053344705'));
SELECT pg_temp.espera_erro($$
  UPDATE tomador SET nivel_verificacao = 2 WHERE usuario_id = '00000000-0000-4000-8000-000000000d01'$$,
  'SC011', 'app não muda o nível do tomador por UPDATE direto');
SELECT pg_temp.aceita($$
  INSERT INTO nivel_verificacao_historico (tomador_id, nivel, origem)
  VALUES ('00000000-0000-4000-8000-000000000d01', 2, 'automatica')$$,
  'app registra mudança de nível no histórico');
SELECT pg_temp.confere(
  (SELECT nivel_verificacao = 2 FROM tomador WHERE usuario_id = '00000000-0000-4000-8000-000000000d01'),
  'nível atual atualizado pelo histórico, com os privilégios do app');
SELECT pg_temp.espera_erro($$UPDATE nivel_verificacao_historico SET nivel = 3$$,
  '42501', 'app não altera o histórico de nível');
SELECT pg_temp.espera_erro($$DELETE FROM nivel_verificacao_historico$$,
  '42501', 'app não apaga o histórico de nível');
SELECT pg_temp.aceita($$
  INSERT INTO auditoria (acao, entidade, papel_bd) VALUES ('teste_app', 'teste', 'safetycar_migrator')$$,
  'app insere na auditoria (o papel_bd enviado é ignorado; conferido em 24_endurecimento_app.sql)');
