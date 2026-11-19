-- 09 — CPF obrigatório (0008): tomador no cadastro; responsável de PJ/MEI na aprovação

CREATE FUNCTION pg_temp.cnpj(p_base text) RETURNS text LANGUAGE sql AS
  $f$ SELECT p_base || cnpj_dv(p_base) $f$;

INSERT INTO usuario (id, keycloak_sub, email, perfil) VALUES
  ('00000000-0000-4000-8000-000000000091', gen_random_uuid(), 'cpf-t1@exemplo.invalid', 'tomador'),
  ('00000000-0000-4000-8000-000000000092', gen_random_uuid(), 'cpf-t2@exemplo.invalid', 'tomador');

-- ---------- Tomador ----------
SELECT pg_temp.confere(
  (SELECT bool_and(attnotnull) FROM pg_attribute
    WHERE attrelid = 'tomador'::regclass AND attname IN ('cpf_cifrado','cpf_hash')),
  'tomador.cpf_cifrado e tomador.cpf_hash são NOT NULL');
SELECT pg_temp.espera_erro($$
  INSERT INTO tomador (usuario_id, nome_completo)
  VALUES ('00000000-0000-4000-8000-000000000091', '[TESTE] Sem CPF')$$,
  '23502', 'tomador sem CPF é rejeitado (CPF exigido no cadastro)');
SELECT pg_temp.espera_erro($$
  INSERT INTO tomador (usuario_id, nome_completo, cpf_cifrado)
  VALUES ('00000000-0000-4000-8000-000000000091', '[TESTE] Só cifrado', '\x01')$$,
  '23502', 'tomador com CPF cifrado e sem hash é rejeitado');
SELECT pg_temp.aceita($$
  INSERT INTO tomador (usuario_id, nome_completo, cpf_cifrado, cpf_hash)
  VALUES ('00000000-0000-4000-8000-000000000091', '[TESTE] Com CPF', '\x01', pg_temp.hmac_teste('39053344705'))$$,
  'tomador com CPF é aceito');
SELECT pg_temp.espera_erro($$
  INSERT INTO tomador (usuario_id, nome_completo, cpf_cifrado, cpf_hash)
  VALUES ('00000000-0000-4000-8000-000000000092', '[TESTE] CPF repetido', '\x02', pg_temp.hmac_teste('39053344705'))$$,
  '23505', 'unicidade do CPF do tomador mantida');
SELECT pg_temp.espera_erro($$
  UPDATE tomador SET cpf_cifrado = NULL, cpf_hash = NULL
   WHERE usuario_id = '00000000-0000-4000-8000-000000000091'$$,
  '23502', 'CPF do tomador não pode ser apagado depois do cadastro');

-- ---------- Responsável de PJ/MEI ----------
INSERT INTO parceiro (id, tipo_pessoa, cnpj, nome, email_comercial, telefone_e164) VALUES
  ('00000000-0000-4000-8000-000000000901', 'pj',  pg_temp.cnpj('940000000001'), '[TESTE] PJ sem responsável',  'r1@exemplo.invalid', '+5511900000901'),
  ('00000000-0000-4000-8000-000000000902', 'mei', pg_temp.cnpj('940000000002'), '[TESTE] MEI sem responsável', 'r2@exemplo.invalid', '+5511900000902');
INSERT INTO parceiro_tipo (parceiro_id, tipo_codigo) VALUES
  ('00000000-0000-4000-8000-000000000901', 'mecanica'),
  ('00000000-0000-4000-8000-000000000902', 'chaveiro');
SELECT pg_temp.confere(
  (SELECT count(*) = 2 FROM parceiro WHERE id IN ('00000000-0000-4000-8000-000000000901',
                                                 '00000000-0000-4000-8000-000000000902')
                                       AND status_credenciamento = 'rascunho'),
  'PJ/MEI sem responsável pode existir em rascunho (exigência é na aprovação)');

SELECT pg_temp.espera_erro($$
  UPDATE parceiro SET status_credenciamento = 'aprovado' WHERE id = '00000000-0000-4000-8000-000000000901'$$,
  'SC014', 'PJ sem CPF do responsável não é aprovada');
SELECT pg_temp.espera_erro($$
  UPDATE parceiro SET status_credenciamento = 'aprovado' WHERE id = '00000000-0000-4000-8000-000000000902'$$,
  'SC014', 'MEI sem CPF do responsável não é aprovado');
SELECT pg_temp.espera_erro($$
  UPDATE parceiro SET responsavel_cpf_hash = pg_temp.hmac_teste('39053344705'), responsavel_nome = '[TESTE] R'
   WHERE id = '00000000-0000-4000-8000-000000000901'$$,
  '23514', 'hash do responsável sem o CPF cifrado é rejeitado');
SELECT pg_temp.espera_erro($$
  UPDATE parceiro SET responsavel_cpf_cifrado = '\x01', responsavel_cpf_hash = pg_temp.hmac_teste('39053344705')
   WHERE id = '00000000-0000-4000-8000-000000000901'$$,
  '23514', 'CPF do responsável sem o nome é rejeitado');

-- O CPF do responsável é o mesmo de um tomador e se repete em duas empresas: aceito (sem UNIQUE).
SELECT pg_temp.aceita($$
  UPDATE parceiro SET responsavel_nome = '[TESTE] Responsável', responsavel_cpf_cifrado = '\x01',
                      responsavel_cpf_hash = pg_temp.hmac_teste('39053344705')
   WHERE id IN ('00000000-0000-4000-8000-000000000901', '00000000-0000-4000-8000-000000000902')$$,
  'mesmo CPF de responsável em duas empresas (e igual ao de um tomador) é aceito');
SELECT pg_temp.aceita($$
  UPDATE parceiro SET status_credenciamento = 'aprovado' WHERE id = '00000000-0000-4000-8000-000000000901'$$,
  'PJ com CPF do responsável é aprovada');
SELECT pg_temp.aceita($$
  UPDATE parceiro SET status_credenciamento = 'aprovado' WHERE id = '00000000-0000-4000-8000-000000000902'$$,
  'MEI com CPF do responsável é aprovado');

SELECT pg_temp.espera_erro($$
  UPDATE parceiro SET responsavel_cpf_cifrado = NULL, responsavel_cpf_hash = NULL, responsavel_nome = NULL
   WHERE id = '00000000-0000-4000-8000-000000000901'$$,
  'SC014', 'parceiro aprovado não pode ficar sem o CPF do responsável');
SELECT pg_temp.aceita($$
  UPDATE parceiro SET responsavel_nome = '[TESTE] Novo responsável', responsavel_cpf_cifrado = '\x02',
                      responsavel_cpf_hash = pg_temp.hmac_teste('16899535009')
   WHERE id = '00000000-0000-4000-8000-000000000901'$$,
  'parceiro aprovado pode trocar o responsável');

-- ---------- PF: sem responsável separado ----------
SELECT pg_temp.espera_erro($$
  INSERT INTO parceiro (tipo_pessoa, cpf_cifrado, cpf_hash, nome, email_comercial, telefone_e164,
                        responsavel_nome, responsavel_cpf_cifrado, responsavel_cpf_hash)
  VALUES ('pf', '\x03', pg_temp.hmac_teste('52998224725'), '[TESTE] PF', 'r4@exemplo.invalid', '+5511900000904',
          '[TESTE] Outro', '\x04', pg_temp.hmac_teste('11144477735'))$$,
  '23514', 'parceiro PF com responsável separado é rejeitado');

-- ---------- Antifraude: bloqueio por CPF alcança o responsável ----------
SELECT pg_temp.confere(
  EXISTS (SELECT 1 FROM parceiro WHERE responsavel_cpf_hash = pg_temp.hmac_teste('16899535009')),
  'hash do responsável é comparável ao do bloqueio (mesma chave e normalização)');
