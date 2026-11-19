-- 14 — Nível 0, "cadastro incompleto" (0013). Valores de nível mínimo FICTÍCIOS (upsert).

INSERT INTO usuario (id, keycloak_sub, email, perfil) VALUES
  ('00000000-0000-4000-8000-000000000e01', gen_random_uuid(), 'n0-t1@exemplo.invalid', 'tomador'),
  ('00000000-0000-4000-8000-000000000e02', gen_random_uuid(), 'n0-t2@exemplo.invalid', 'tomador');

-- ---------- Catálogo ----------
SELECT pg_temp.confere(
  (SELECT nome = 'Cadastro incompleto' FROM nivel_verificacao WHERE nivel = 0),
  'nível 0 "Cadastro incompleto" no catálogo');
SELECT pg_temp.confere(
  EXISTS (SELECT 1 FROM auditoria WHERE entidade = 'nivel_verificacao' AND acao = 'parametrizacao_insert'
             AND depois ->> 'nivel' = '0' AND papel_bd = 'safetycar_migrator'),
  'inclusão do nível 0 ficou na auditoria');
SELECT pg_temp.espera_erro($$INSERT INTO nivel_verificacao (nivel, nome) VALUES (-1, 'x')$$,
  '23514', 'nível negativo é rejeitado');
SELECT pg_temp.confere(
  (SELECT bool_and(column_default = '0') FROM information_schema.columns
    WHERE table_name IN ('tomador','parceiro') AND column_name = 'nivel_verificacao'),
  'padrão do nível atual é 0 em tomador e parceiro');

-- ---------- Novo cadastro nasce no nível 0 ----------
INSERT INTO tomador (usuario_id, nome_completo, cpf_cifrado, cpf_hash) VALUES
  ('00000000-0000-4000-8000-000000000e01', '[TESTE] Tomador N0', '\x01', pg_temp.hmac_teste('39053344705'));
INSERT INTO parceiro (id, tipo_pessoa, cpf_cifrado, cpf_hash, nome, email_comercial, telefone_e164) VALUES
  ('00000000-0000-4000-8000-000000000e11', 'pf', '\x02', pg_temp.hmac_teste('16899535009'),
   '[TESTE] Parceiro N0', 'n0-p@exemplo.invalid', '+5511900000811');
SELECT pg_temp.confere(
  (SELECT nivel_verificacao = 0 FROM tomador WHERE usuario_id = '00000000-0000-4000-8000-000000000e01'),
  'tomador novo nasce no nível 0');
SELECT pg_temp.confere(
  (SELECT nivel_verificacao = 0 FROM parceiro WHERE id = '00000000-0000-4000-8000-000000000e11'),
  'parceiro novo nasce no nível 0');
SELECT pg_temp.espera_erro($$
  INSERT INTO tomador (usuario_id, nome_completo, cpf_cifrado, cpf_hash, nivel_verificacao)
  VALUES ('00000000-0000-4000-8000-000000000e02', '[TESTE] Já no 1', '\x03', pg_temp.hmac_teste('52998224725'), 1)$$,
  'SC011', 'tomador não pode nascer no nível 1 (o antigo padrão)');

-- ---------- Promoção ao 1 só pelo histórico ----------
SELECT pg_temp.espera_erro($$
  UPDATE tomador SET nivel_verificacao = 1 WHERE usuario_id = '00000000-0000-4000-8000-000000000e01'$$,
  'SC011', 'promoção do tomador ao nível 1 por UPDATE direto é recusada');
SELECT pg_temp.espera_erro($$
  UPDATE parceiro SET nivel_verificacao = 1 WHERE id = '00000000-0000-4000-8000-000000000e11'$$,
  'SC011', 'promoção do parceiro ao nível 1 por UPDATE direto é recusada');
SELECT pg_temp.aceita($$
  INSERT INTO nivel_verificacao_historico (tomador_id, nivel, origem)
  VALUES ('00000000-0000-4000-8000-000000000e01', 1, 'automatica')$$,
  'promoção do tomador ao nível 1 por linha de histórico');
SELECT pg_temp.confere(
  (SELECT t.nivel_verificacao = 1 AND h.nivel_anterior = 0
     FROM tomador t JOIN nivel_verificacao_historico h ON h.tomador_id = t.usuario_id
    WHERE t.usuario_id = '00000000-0000-4000-8000-000000000e01'),
  'nível atual 1 e histórico registra a saída do nível 0');
SELECT pg_temp.aceita($$
  INSERT INTO nivel_verificacao_historico (parceiro_id, nivel, origem)
  VALUES ('00000000-0000-4000-8000-000000000e11', 1, 'automatica')$$,
  'promoção do parceiro ao nível 1 por linha de histórico');
SELECT pg_temp.aceita($$
  INSERT INTO nivel_verificacao_historico (tomador_id, nivel, origem, motivo)
  VALUES ('00000000-0000-4000-8000-000000000e01', 0, 'migracao', '[TESTE] rebaixamento por migração')$$,
  'rebaixamento ao nível 0 pelo histórico, com a origem "migracao"');
SELECT pg_temp.confere(
  (SELECT nivel_verificacao = 0 FROM tomador WHERE usuario_id = '00000000-0000-4000-8000-000000000e01'),
  'rebaixado volta ao nível 0');
SELECT pg_temp.espera_erro($$
  INSERT INTO nivel_verificacao_historico (tomador_id, nivel, origem)
  VALUES ('00000000-0000-4000-8000-000000000e01', 1, 'inventada')$$,
  '23514', 'origem fora da lista continua rejeitada');

-- ---------- Nível 0 não cumpre o mínimo de nenhum serviço ----------
INSERT INTO servico_nivel_minimo (servico_codigo, perfil, nivel_minimo, situacao)
SELECT s.codigo, p.perfil, 1, 'definido'
  FROM servico_catalogo s CROSS JOIN (VALUES ('tomador'), ('parceiro')) AS p(perfil)
ON CONFLICT (servico_codigo, perfil) DO UPDATE SET nivel_minimo = 1, situacao = 'definido';

SELECT pg_temp.confere(
  (SELECT bool_and(NOT cumpre_nivel_minimo(p.perfil, 0, s.codigo))
     FROM servico_catalogo s CROSS JOIN (VALUES ('tomador'), ('parceiro')) AS p(perfil)),
  'nível 0 não cumpre o mínimo de nenhum serviço, em nenhum perfil (mínimo mais baixo possível: 1)');
SELECT pg_temp.confere(
  (SELECT bool_and(cumpre_nivel_minimo(p.perfil, 1, s.codigo))
     FROM servico_catalogo s CROSS JOIN (VALUES ('tomador'), ('parceiro')) AS p(perfil)),
  'nível 1 cumpre mínimo 1 (controle do teste acima)');

-- ---------- SC013 preservado ----------
UPDATE servico_nivel_minimo SET nivel_minimo = NULL, situacao = 'a_definir'
 WHERE servico_codigo = 'guincho_leve' AND perfil = 'tomador';
SELECT pg_temp.espera_erro($$SELECT cumpre_nivel_minimo('tomador', 0, 'guincho_leve')$$,
  'SC013', 'nível 0 com mínimo "a definir": recusa SC013 (não responde false nem trata como zero)');
SELECT pg_temp.espera_erro($$SELECT cumpre_nivel_minimo('tomador', 3, 'guincho_leve')$$,
  'SC013', 'nível 3 com mínimo "a definir": recusa SC013');

-- ---------- Nível inválido ----------
SELECT pg_temp.espera_erro($$SELECT cumpre_nivel_minimo('tomador', 4, 'pneu')$$,
  '22023', 'nível 4 é parâmetro inválido');
SELECT pg_temp.espera_erro($$SELECT cumpre_nivel_minimo('tomador', -1, 'pneu')$$,
  '22023', 'nível negativo é parâmetro inválido');
SELECT pg_temp.espera_erro($$SELECT cumpre_nivel_minimo('tomador', NULL, 'pneu')$$,
  '22023', 'nível nulo é parâmetro inválido (não devolve NULL)');

-- ---------- Onde o nível 0 não cabe ----------
SELECT pg_temp.espera_erro($$
  UPDATE servico_nivel_minimo SET nivel_minimo = 0, situacao = 'definido'
   WHERE servico_codigo = 'pneu' AND perfil = 'tomador'$$,
  '23514', 'nível mínimo de serviço igual a 0 é recusado');
SELECT pg_temp.espera_erro($$
  INSERT INTO nivel_requisito (perfil, requisito_codigo, nivel) VALUES ('tomador', 'email', 0)
  ON CONFLICT (perfil, requisito_codigo) DO UPDATE SET nivel = EXCLUDED.nivel$$,
  '23514', 'requisito no nível 0 é recusado (nível 0 não tem requisitos)');
SELECT pg_temp.espera_erro($$
  INSERT INTO politica_garantia (servico_codigo, nivel_verificacao, modalidade, calculo, valor_centavos, situacao)
  VALUES ('pneu', 0, 'pix_pre_pago', 'valor_fixo', 0, 'a_definir')$$,
  '23514', 'política de garantia no nível 0 é recusada');
SELECT pg_temp.espera_erro($$SELECT politica_garantia_vigente('pneu', 0, 'pix_pre_pago')$$,
  '22023', 'garantia consultada para o nível 0: não se aplica (22023, não SC013)');
SELECT pg_temp.espera_erro($$SELECT politica_garantia_vigente('pneu', 1, 'pix_pre_pago')$$,
  'SC013', 'garantia "a definir" no nível 1 continua SC013');
