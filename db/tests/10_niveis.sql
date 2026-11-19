-- 10 — Níveis de verificação (0009): requisitos, nível mínimo por serviço, histórico e auditoria.
-- Os valores usados aqui são FICTÍCIOS (upsert), independentes da carga da 0012.

INSERT INTO usuario (id, keycloak_sub, email, perfil) VALUES
  ('00000000-0000-4000-8000-000000000a01', gen_random_uuid(), 'niv-t1@exemplo.invalid', 'tomador'),
  ('00000000-0000-4000-8000-000000000a02', gen_random_uuid(), 'niv-c1@exemplo.invalid', 'central');
INSERT INTO tomador (usuario_id, nome_completo, cpf_cifrado, cpf_hash) VALUES
  ('00000000-0000-4000-8000-000000000a01', '[TESTE] Tomador Nível', '\x01', pg_temp.hmac_teste('39053344705'));
INSERT INTO parceiro (id, tipo_pessoa, cpf_cifrado, cpf_hash, nome, email_comercial, telefone_e164) VALUES
  ('00000000-0000-4000-8000-000000000a11', 'pf', '\x02', pg_temp.hmac_teste('16899535009'),
   '[TESTE] Parceiro Nível', 'niv-p@exemplo.invalid', '+5511900000911');

-- ---------- Catálogos ----------
SELECT pg_temp.confere((SELECT array_agg(nivel ORDER BY nivel) = '{0,1,2,3}' FROM nivel_verificacao),
  'catálogo com os níveis 0 (cadastro incompleto, 0013), 1, 2 e 3');
SELECT pg_temp.espera_erro($$INSERT INTO nivel_verificacao (nivel, nome) VALUES (4, 'x')$$,
  '23514', 'nível fora de 0 a 3 é rejeitado');
SELECT pg_temp.confere((SELECT count(*) = 8 FROM requisito_verificacao),
  'catálogo de requisitos com 8 itens');

-- ---------- Requisito x perfil ----------
SELECT pg_temp.espera_erro($$
  INSERT INTO nivel_requisito (perfil, requisito_codigo, nivel) VALUES ('tomador', 'documentos_parceiro', 3)
  ON CONFLICT (perfil, requisito_codigo) DO UPDATE SET nivel = EXCLUDED.nivel$$,
  'SC015', 'documentos do parceiro não se aplicam ao tomador');
SELECT pg_temp.espera_erro($$
  INSERT INTO nivel_requisito (perfil, requisito_codigo, nivel) VALUES ('parceiro', 'meio_pagamento_garantia', 3)
  ON CONFLICT (perfil, requisito_codigo) DO UPDATE SET nivel = EXCLUDED.nivel$$,
  'SC015', 'meio de pagamento da garantia não se aplica ao parceiro');
SELECT pg_temp.aceita($$
  INSERT INTO nivel_requisito (perfil, requisito_codigo, nivel) VALUES ('tomador', 'selfie', 2)
  ON CONFLICT (perfil, requisito_codigo) DO UPDATE SET nivel = EXCLUDED.nivel$$,
  'requisito compatível com o perfil é aceito');

-- ---------- Nível mínimo por serviço ----------
SELECT pg_temp.espera_erro($$
  INSERT INTO servico_nivel_minimo (servico_codigo, perfil, situacao) VALUES ('guincho_leve', 'tomador', 'definido')
  ON CONFLICT (servico_codigo, perfil) DO UPDATE SET situacao = EXCLUDED.situacao, nivel_minimo = NULL$$,
  '23514', '"definido" sem nível é rejeitado');
SELECT pg_temp.espera_erro($$
  INSERT INTO servico_nivel_minimo (servico_codigo, perfil, nivel_minimo, situacao) VALUES ('guincho_leve', 'tomador', 2, 'a_definir')
  ON CONFLICT (servico_codigo, perfil) DO UPDATE SET situacao = EXCLUDED.situacao, nivel_minimo = EXCLUDED.nivel_minimo$$,
  '23514', '"a definir" com nível é rejeitado');

INSERT INTO servico_nivel_minimo (servico_codigo, perfil, nivel_minimo, situacao) VALUES
  ('guincho_leve',   'tomador',  2,    'definido'),
  ('guincho_leve',   'parceiro', NULL, 'a_definir'),
  ('guincho_pesado', 'tomador',  NULL, 'a_definir')
ON CONFLICT (servico_codigo, perfil) DO UPDATE
  SET nivel_minimo = EXCLUDED.nivel_minimo, situacao = EXCLUDED.situacao;
INSERT INTO servico_nivel_minimo (servico_codigo, perfil) VALUES ('chaveiro', 'tomador') ON CONFLICT DO NOTHING;
DELETE FROM servico_nivel_minimo WHERE servico_codigo = 'chaveiro' AND perfil = 'tomador';

SELECT pg_temp.confere(nivel_minimo_servico('guincho_leve', 'tomador') = 2,
  'nível mínimo definido é devolvido');
SELECT pg_temp.confere(NOT cumpre_nivel_minimo('tomador', 1, 'guincho_leve'),
  'tomador nível 1 não atende serviço de mínimo 2');
SELECT pg_temp.confere(cumpre_nivel_minimo('tomador', 2, 'guincho_leve') AND cumpre_nivel_minimo('tomador', 3, 'guincho_leve'),
  'tomador nível 2 ou 3 atende serviço de mínimo 2');
SELECT pg_temp.espera_erro($$SELECT cumpre_nivel_minimo('parceiro', 3, 'guincho_leve')$$,
  'SC013', 'mínimo do parceiro "a definir" é recusado, mesmo com nível 3 (não vira zero nem 1)');
SELECT pg_temp.espera_erro($$SELECT nivel_minimo_servico('guincho_pesado', 'tomador')$$,
  'SC013', 'mínimo "a definir" é recusado');
SELECT pg_temp.espera_erro($$SELECT nivel_minimo_servico('chaveiro', 'tomador')$$,
  'SC013', 'serviço sem linha de nível mínimo é recusado');
SELECT pg_temp.espera_erro($$SELECT nivel_minimo_servico('teletransporte', 'tomador')$$,
  '22023', 'serviço inexistente é parâmetro inválido');
SELECT pg_temp.espera_erro($$SELECT nivel_minimo_servico('guincho_leve', 'central')$$,
  '22023', 'perfil fora de tomador/parceiro é parâmetro inválido');

-- ---------- Nível atual só pelo histórico ----------
SELECT pg_temp.espera_erro($$
  INSERT INTO usuario (id, keycloak_sub, email, perfil)
  VALUES ('00000000-0000-4000-8000-000000000a03', gen_random_uuid(), 'niv-t3@exemplo.invalid', 'tomador');
  INSERT INTO tomador (usuario_id, nome_completo, cpf_cifrado, cpf_hash, nivel_verificacao)
  VALUES ('00000000-0000-4000-8000-000000000a03', '[TESTE] Já nível 3', '\x03', pg_temp.hmac_teste('52998224725'), 3)$$,
  'SC011', 'tomador não nasce acima do nível 0 (desde a 0013)');
SELECT pg_temp.espera_erro($$
  UPDATE tomador SET nivel_verificacao = 3 WHERE usuario_id = '00000000-0000-4000-8000-000000000a01'$$,
  'SC011', 'nível do tomador não muda por UPDATE direto');
SELECT pg_temp.espera_erro($$
  UPDATE parceiro SET nivel_verificacao = 2 WHERE id = '00000000-0000-4000-8000-000000000a11'$$,
  'SC011', 'nível do parceiro não muda por UPDATE direto');

SELECT pg_temp.aceita($$
  INSERT INTO nivel_verificacao_historico (tomador_id, nivel, origem, nivel_anterior, concedido_em)
  VALUES ('00000000-0000-4000-8000-000000000a01', 2, 'automatica', 3, '2000-01-01')$$,
  'histórico automático concede nível 2 ao tomador');
SELECT pg_temp.confere(
  (SELECT nivel_verificacao = 2 FROM tomador WHERE usuario_id = '00000000-0000-4000-8000-000000000a01'),
  'nível atual do tomador acompanha o histórico');
SELECT pg_temp.confere(
  (SELECT nivel_anterior = 0 AND concedido_em > now() - interval '1 minute'
     FROM nivel_verificacao_historico WHERE tomador_id = '00000000-0000-4000-8000-000000000a01'),
  'nível anterior e hora vêm do servidor (valores enviados são ignorados)');

SELECT pg_temp.espera_erro($$
  INSERT INTO nivel_verificacao_historico (parceiro_id, nivel, origem, motivo)
  VALUES ('00000000-0000-4000-8000-000000000a11', 3, 'central', '[TESTE] sem concedente')$$,
  '23514', 'concessão da Central sem concedido_por é rejeitada');
SELECT pg_temp.espera_erro($$
  INSERT INTO nivel_verificacao_historico (parceiro_id, nivel, origem, concedido_por, motivo)
  VALUES ('00000000-0000-4000-8000-000000000a11', 3, 'central', '00000000-0000-4000-8000-000000000a01', '[TESTE]')$$,
  'SC001', 'concessão manual só por usuário central');
SELECT pg_temp.espera_erro($$
  INSERT INTO nivel_verificacao_historico (tomador_id, parceiro_id, nivel, origem)
  VALUES ('00000000-0000-4000-8000-000000000a01', '00000000-0000-4000-8000-000000000a11', 2, 'automatica')$$,
  '23514', 'histórico com tomador e parceiro ao mesmo tempo é rejeitado');
SELECT pg_temp.aceita($$
  INSERT INTO nivel_verificacao_historico (parceiro_id, nivel, origem, concedido_por, motivo)
  VALUES ('00000000-0000-4000-8000-000000000a11', 3, 'central', '00000000-0000-4000-8000-000000000a02', '[TESTE] análise manual')$$,
  'Central concede nível 3 ao parceiro, com motivo');
SELECT pg_temp.aceita($$
  INSERT INTO nivel_verificacao_historico (parceiro_id, nivel, origem, concedido_por, motivo)
  VALUES ('00000000-0000-4000-8000-000000000a11', 1, 'central', '00000000-0000-4000-8000-000000000a02', '[TESTE] rebaixamento')$$,
  'Central rebaixa o parceiro (o histórico também registra redução)');
SELECT pg_temp.confere(
  (SELECT nivel_verificacao = 1 FROM parceiro WHERE id = '00000000-0000-4000-8000-000000000a11'),
  'nível atual do parceiro segue o registro mais recente');

SELECT pg_temp.espera_erro($$UPDATE nivel_verificacao_historico SET nivel = 3$$,
  'SC010', 'histórico de nível não aceita UPDATE');
SELECT pg_temp.espera_erro($$DELETE FROM nivel_verificacao_historico$$,
  'SC010', 'histórico de nível não aceita DELETE');

-- ---------- Auditoria da parametrização ----------
SET LOCAL safetycar.ator_usuario_id = '00000000-0000-4000-8000-000000000a02';
UPDATE servico_nivel_minimo SET observacao = '[TESTE] auditado'
 WHERE servico_codigo = 'guincho_leve' AND perfil = 'tomador';
RESET safetycar.ator_usuario_id;
SELECT pg_temp.confere(
  EXISTS (SELECT 1 FROM auditoria
           WHERE entidade = 'servico_nivel_minimo' AND acao = 'parametrizacao_update'
             AND ator_usuario_id = '00000000-0000-4000-8000-000000000a02'
             AND papel_bd = 'safetycar_migrator'
             AND antes ->> 'observacao' IS DISTINCT FROM '[TESTE] auditado'
             AND depois ->> 'observacao' = '[TESTE] auditado'),
  'alteração de parametrização vai para a auditoria com ator, papel do banco, antes e depois');
SELECT pg_temp.confere(
  EXISTS (SELECT 1 FROM auditoria WHERE entidade = 'servico_nivel_minimo' AND acao = 'parametrizacao_delete'
             AND antes ->> 'servico_codigo' = 'chaveiro' AND papel_bd = 'safetycar_migrator'),
  'exclusão de parametrização é auditada (sem ator = sistema/migração)');
SELECT pg_temp.confere(
  (SELECT count(*) = 3 FROM auditoria WHERE entidade = 'nivel_verificacao_historico'),
  'cada mudança de nível também é auditada');
SELECT pg_temp.espera_erro($$TRUNCATE servico_nivel_minimo$$,
  'SC010', 'TRUNCATE em parametrização é bloqueado');

INSERT INTO auditoria (acao, entidade, papel_bd) VALUES ('teste_papel', 'teste', 'papel_forjado');
SELECT pg_temp.confere(
  (SELECT papel_bd = current_user FROM auditoria WHERE acao = 'teste_papel'),
  'papel_bd é sempre o papel real (valor enviado é ignorado)');
