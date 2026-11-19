-- 05 — Parceiro: pessoa física/jurídica, tipos, viaturas, Susep, serviços, membros

CREATE FUNCTION pg_temp.cnpj(p_base text) RETURNS text LANGUAGE sql AS
  $f$ SELECT p_base || cnpj_dv(p_base) $f$;

INSERT INTO usuario (id, keycloak_sub, email, perfil) VALUES
  ('00000000-0000-4000-8000-000000000021', gen_random_uuid(), 'membro1@exemplo.invalid',  'parceiro'),
  ('00000000-0000-4000-8000-000000000022', gen_random_uuid(), 'membro2@exemplo.invalid',  'parceiro'),
  ('00000000-0000-4000-8000-000000000023', gen_random_uuid(), 'tomador@exemplo.invalid',  'tomador'),
  ('00000000-0000-4000-8000-000000000024', gen_random_uuid(), 'central@exemplo.invalid',  'central');

-- ---------- Pessoa física / jurídica ----------
SELECT pg_temp.espera_erro($$
  INSERT INTO parceiro (tipo_pessoa, nome, email_comercial, telefone_e164)
  VALUES ('pj', '[TESTE] PJ sem CNPJ', 'pj@exemplo.invalid', '+5511900000100')$$,
  '23514', 'PJ sem CNPJ é rejeitado');
SELECT pg_temp.espera_erro($$
  INSERT INTO parceiro (tipo_pessoa, nome, email_comercial, telefone_e164)
  VALUES ('mei', '[TESTE] MEI sem CNPJ', 'mei@exemplo.invalid', '+5511900000101')$$,
  '23514', 'MEI sem CNPJ é rejeitado');
SELECT pg_temp.espera_erro($$
  INSERT INTO parceiro (tipo_pessoa, cnpj, nome, email_comercial, telefone_e164)
  VALUES ('pf', pg_temp.cnpj('900000000001'), '[TESTE] PF sem CPF', 'pf@exemplo.invalid', '+5511900000102')$$,
  '23514', 'PF sem cpf_hash é rejeitado (CNPJ não substitui)');
SELECT pg_temp.aceita($$
  INSERT INTO parceiro (tipo_pessoa, cpf_cifrado, cpf_hash, nome, email_comercial, telefone_e164)
  VALUES ('pf', '\x01', pg_temp.hmac_teste('11144477735'), '[TESTE] Chaveiro PF', 'pf@exemplo.invalid', '+5511900000103')$$,
  'PF com cpf_hash é aceito');
SELECT pg_temp.espera_erro($$
  INSERT INTO parceiro (tipo_pessoa, cpf_cifrado, cpf_hash, nome, email_comercial, telefone_e164)
  VALUES ('pf', '\x02', pg_temp.hmac_teste('11144477735'), '[TESTE] PF repetido', 'pf2@exemplo.invalid', '+5511900000104')$$,
  '23505', 'cpf_hash duplicado entre parceiros é rejeitado');
SELECT pg_temp.espera_erro($$
  INSERT INTO parceiro (tipo_pessoa, cnpj, nome, email_comercial, telefone_e164)
  VALUES ('pj', '11222333000182', '[TESTE] CNPJ DV errado', 'x@exemplo.invalid', '+5511900000105')$$,
  '23514', 'parceiro com CNPJ de DV errado é rejeitado');
SELECT pg_temp.espera_erro($$
  INSERT INTO parceiro (tipo_pessoa, cnpj, nome, email_comercial, telefone_e164)
  VALUES ('pj', pg_temp.cnpj('900000000002'), '[TESTE] Telefone ruim', 'x@exemplo.invalid', '11 9000-0000')$$,
  '23514', 'parceiro com telefone fora de E.164 é rejeitado');

-- Parceiros base (PJ/MEI com responsável: exigido na aprovação desde a 0008; ver 09_cpf_obrigatorio.sql)
INSERT INTO parceiro (id, tipo_pessoa, cnpj, nome, email_comercial, telefone_e164,
                      responsavel_nome, responsavel_cpf_cifrado, responsavel_cpf_hash) VALUES
  ('00000000-0000-4000-8000-0000000000a1', 'pj',  pg_temp.cnpj('900000000010'), '[TESTE] Guincho Ltda',  'g@exemplo.invalid',  '+5511900000110',
   '[TESTE] Responsável', '\x10', pg_temp.hmac_teste('39053344705')),
  ('00000000-0000-4000-8000-0000000000a2', 'pj',  pg_temp.cnpj('900000000020'), '[TESTE] Seguros S.A.',  's@exemplo.invalid',  '+5511900000120',
   '[TESTE] Responsável', '\x10', pg_temp.hmac_teste('39053344705')),
  ('00000000-0000-4000-8000-0000000000a3', 'mei', pg_temp.cnpj('90000000003A'), '[TESTE] Mecânica MEI',  'm@exemplo.invalid',  '+5511900000130',
   '[TESTE] Titular MEI', '\x11', pg_temp.hmac_teste('16899535009')),
  ('00000000-0000-4000-8000-0000000000a4', 'pj',  pg_temp.cnpj('900000000040'), '[TESTE] Sem tipo',      'n@exemplo.invalid',  '+5511900000140',
   '[TESTE] Responsável', '\x10', pg_temp.hmac_teste('39053344705'));

SELECT pg_temp.espera_erro($$
  INSERT INTO parceiro (tipo_pessoa, cnpj, nome, email_comercial, telefone_e164)
  VALUES ('pj', pg_temp.cnpj('900000000010'), '[TESTE] CNPJ repetido', 'r@exemplo.invalid', '+5511900000150')$$,
  '23505', 'CNPJ duplicado é rejeitado');

INSERT INTO parceiro_tipo (parceiro_id, tipo_codigo) VALUES
  ('00000000-0000-4000-8000-0000000000a1', 'guincho'),
  ('00000000-0000-4000-8000-0000000000a2', 'seguros'),
  ('00000000-0000-4000-8000-0000000000a3', 'mecanica');

SELECT pg_temp.aceita($$
  INSERT INTO parceiro_tipo (parceiro_id, tipo_codigo)
  VALUES ('00000000-0000-4000-8000-0000000000a3', 'chaveiro')$$,
  'parceiro com mais de um tipo (mecânica + chaveiro)');

-- ---------- Viatura só para tipo que permite ----------
SELECT pg_temp.espera_erro($$
  INSERT INTO parceiro_viatura (parceiro_id, placa, tipo)
  VALUES ('00000000-0000-4000-8000-0000000000a2', 'SEG1A23', 'outro')$$,
  'SC002', 'viatura para parceiro só de seguros é rejeitada');
SELECT pg_temp.espera_erro($$
  INSERT INTO parceiro_viatura (parceiro_id, placa, tipo)
  VALUES ('00000000-0000-4000-8000-0000000000a4', 'SEM1A23', 'outro')$$,
  'SC002', 'viatura para parceiro sem tipo é rejeitada');
SELECT pg_temp.aceita($$
  INSERT INTO parceiro_viatura (parceiro_id, placa, tipo)
  VALUES ('00000000-0000-4000-8000-0000000000a3', 'MEC1B23', 'utilitario_mecanico')$$,
  'viatura para mecânica (tipo que permite viatura)');

-- ---------- Aprovação: guincho exige viatura ----------
SELECT pg_temp.espera_erro($$
  UPDATE parceiro SET status_credenciamento = 'aprovado'
   WHERE id = '00000000-0000-4000-8000-0000000000a1'$$,
  'SC004', 'guincho sem viatura ativa não pode ser aprovado');
INSERT INTO parceiro_viatura (id, parceiro_id, placa, tipo) VALUES
  ('00000000-0000-4000-8000-0000000000b1', '00000000-0000-4000-8000-0000000000a1', 'GUI1C23', 'guincho_plataforma');
SELECT pg_temp.aceita($$
  UPDATE parceiro SET status_credenciamento = 'aprovado', aprovado_em = now(),
                      aprovado_por = '00000000-0000-4000-8000-000000000024'
   WHERE id = '00000000-0000-4000-8000-0000000000a1'$$,
  'guincho com viatura ativa é aprovado (aprovador de perfil central)');
SELECT pg_temp.aceita($$
  UPDATE parceiro SET status_credenciamento = 'aprovado'
   WHERE id = '00000000-0000-4000-8000-0000000000a3'$$,
  'mecânica sem exigência de viatura/Susep é aprovada');
SELECT pg_temp.espera_erro($$
  UPDATE parceiro SET status_credenciamento = 'aprovado'
   WHERE id = '00000000-0000-4000-8000-0000000000a4'$$,
  'SC007', 'parceiro sem nenhum tipo não pode ser aprovado');
SELECT pg_temp.espera_erro($$
  UPDATE parceiro SET aprovado_por = '00000000-0000-4000-8000-000000000023'
   WHERE id = '00000000-0000-4000-8000-0000000000a3'$$,
  'SC001', 'aprovador precisa ter perfil central');

-- ---------- Aprovação: seguros exige registro Susep aprovado ----------
SELECT pg_temp.espera_erro($$
  UPDATE parceiro SET status_credenciamento = 'aprovado'
   WHERE id = '00000000-0000-4000-8000-0000000000a2'$$,
  'SC003', 'seguros sem registro_susep não pode ser aprovado');
INSERT INTO parceiro_documento (id, parceiro_id, tipo, arquivo_ref, sha256) VALUES
  ('00000000-0000-4000-8000-0000000000c1', '00000000-0000-4000-8000-0000000000a2',
   'registro_susep', 'teste/susep.pdf', repeat('a', 64));
SELECT pg_temp.espera_erro($$
  UPDATE parceiro SET status_credenciamento = 'aprovado'
   WHERE id = '00000000-0000-4000-8000-0000000000a2'$$,
  'SC003', 'seguros com registro_susep só enviado (não aprovado) não pode ser aprovado');
UPDATE parceiro_documento SET status = 'aprovado', revisado_por = '00000000-0000-4000-8000-000000000024', revisado_em = now()
 WHERE id = '00000000-0000-4000-8000-0000000000c1';
SELECT pg_temp.aceita($$
  UPDATE parceiro SET status_credenciamento = 'aprovado'
   WHERE id = '00000000-0000-4000-8000-0000000000a2'$$,
  'seguros com registro_susep aprovado é aprovado');

-- ---------- Serviços de socorro só para tipos de assistência ----------
SELECT pg_temp.espera_erro($$
  INSERT INTO parceiro_servico (parceiro_id, servico_codigo)
  VALUES ('00000000-0000-4000-8000-0000000000a2', 'guincho_leve')$$,
  'SC005', 'serviço de socorro para parceiro só de seguros é rejeitado');
SELECT pg_temp.aceita($$
  INSERT INTO parceiro_servico (parceiro_id, servico_codigo)
  VALUES ('00000000-0000-4000-8000-0000000000a1', 'guincho_leve')$$,
  'serviço de socorro para guincho');

-- ---------- Remoção de tipo ----------
SELECT pg_temp.espera_erro($$
  DELETE FROM parceiro_tipo WHERE parceiro_id = '00000000-0000-4000-8000-0000000000a1'$$,
  'SC006', 'remover o único tipo de um guincho com viatura ativa é bloqueado');
SELECT pg_temp.aceita($$
  DELETE FROM parceiro_tipo
   WHERE parceiro_id = '00000000-0000-4000-8000-0000000000a3' AND tipo_codigo = 'chaveiro'$$,
  'remover um dos tipos quando outro ainda permite viatura');

-- ---------- Tipo inativo ----------
UPDATE tipo_parceiro SET ativo = false WHERE codigo = 'chaveiro';
SELECT pg_temp.espera_erro($$
  INSERT INTO parceiro_tipo (parceiro_id, tipo_codigo)
  VALUES ('00000000-0000-4000-8000-0000000000a4', 'chaveiro')$$,
  'SC008', 'vínculo com tipo inativo é rejeitado');
UPDATE tipo_parceiro SET ativo = true WHERE codigo = 'chaveiro';

-- ---------- Membros ----------
SELECT pg_temp.aceita($$
  INSERT INTO parceiro_membro (parceiro_id, usuario_id, papel)
  VALUES ('00000000-0000-4000-8000-0000000000a1', '00000000-0000-4000-8000-000000000021', 'proprietario')$$,
  'membro de perfil parceiro');
SELECT pg_temp.espera_erro($$
  INSERT INTO parceiro_membro (parceiro_id, usuario_id, papel)
  VALUES ('00000000-0000-4000-8000-0000000000a3', '00000000-0000-4000-8000-000000000021', 'administrador')$$,
  '23505', 'usuário em dois parceiros é rejeitado');
SELECT pg_temp.espera_erro($$
  INSERT INTO parceiro_membro (parceiro_id, usuario_id, papel)
  VALUES ('00000000-0000-4000-8000-0000000000a1', '00000000-0000-4000-8000-000000000023', 'despachante')$$,
  'SC001', 'usuário de perfil tomador não pode ser membro de parceiro');
SELECT pg_temp.espera_erro($$
  UPDATE usuario SET perfil = 'tomador' WHERE id = '00000000-0000-4000-8000-000000000021'$$,
  'SC001', 'membro de parceiro não troca de perfil');

-- ---------- Documentos: vínculos coerentes ----------
SELECT pg_temp.espera_erro($$
  INSERT INTO parceiro_documento (parceiro_id, viatura_id, tipo, arquivo_ref, sha256)
  VALUES ('00000000-0000-4000-8000-0000000000a3', '00000000-0000-4000-8000-0000000000b1',
          'crlv', 'teste/crlv.pdf', repeat('b', 64))$$,
  '23503', 'documento de viatura de outro parceiro é rejeitado');
SELECT pg_temp.espera_erro($$
  INSERT INTO parceiro_documento (parceiro_id, usuario_id, tipo, arquivo_ref, sha256)
  VALUES ('00000000-0000-4000-8000-0000000000a3', '00000000-0000-4000-8000-000000000021',
          'cnh', 'teste/cnh.pdf', repeat('c', 64))$$,
  '23503', 'documento pessoal de quem não é membro do parceiro é rejeitado');
SELECT pg_temp.aceita($$
  INSERT INTO parceiro_documento (parceiro_id, usuario_id, viatura_id, tipo, arquivo_ref, sha256)
  VALUES ('00000000-0000-4000-8000-0000000000a1', '00000000-0000-4000-8000-000000000021',
          NULL, 'cnh', 'teste/cnh.pdf', repeat('d', 64))$$,
  'CNH de membro do próprio parceiro');
