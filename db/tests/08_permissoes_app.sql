-- 08 — Permissões: este arquivo roda CONECTADO como safetycar_app.

SELECT pg_temp.confere(current_user = 'safetycar_app', 'teste conectado como safetycar_app');
SELECT pg_temp.confere(
  (SELECT NOT rolsuper AND NOT rolcreatedb AND NOT rolcreaterole AND NOT rolreplication AND NOT rolbypassrls
     FROM pg_roles WHERE rolname = 'safetycar_app'),
  'safetycar_app sem superusuário, CREATEDB, CREATEROLE, REPLICATION ou BYPASSRLS');

-- ---------- Sem DDL ----------
SELECT pg_temp.espera_erro($$CREATE TABLE public.invasora (id int)$$,
  '42501', 'app não cria tabela no schema public');
SELECT pg_temp.espera_erro($$CREATE FUNCTION public.f_invasora() RETURNS int LANGUAGE sql AS 'SELECT 1'$$,
  '42501', 'app não cria função no schema public');
SELECT pg_temp.espera_erro($$CREATE SCHEMA invasor$$,
  '42501', 'app não cria schema');
SELECT pg_temp.espera_erro($$ALTER TABLE usuario ADD COLUMN x int$$,
  '42501', 'app não altera tabela');
SELECT pg_temp.espera_erro($$DROP TABLE parceiro_posicao_atual$$,
  '42501', 'app não apaga tabela');
SELECT pg_temp.espera_erro($$DROP TRIGGER tg_auditoria_sem_alteracao ON auditoria$$,
  '42501', 'app não remove o trigger da auditoria');

-- ---------- Auditoria: só inserção ----------
SELECT pg_temp.aceita($$
  INSERT INTO auditoria (acao, entidade, depois) VALUES ('teste', 'permissao', '{"teste": true}')$$,
  'app insere na auditoria');
SELECT pg_temp.espera_erro($$DELETE FROM auditoria$$, '42501', 'app não apaga auditoria');
SELECT pg_temp.espera_erro($$UPDATE auditoria SET acao = 'x'$$, '42501', 'app não altera auditoria');
SELECT pg_temp.espera_erro($$TRUNCATE auditoria$$, '42501', 'app não trunca auditoria');

-- ---------- Catálogos e controle de migração: só leitura ----------
SELECT pg_temp.confere((SELECT count(*) = 4 FROM tipo_parceiro), 'app lê o catálogo de tipos');
SELECT pg_temp.espera_erro($$INSERT INTO tipo_parceiro (codigo, nome) VALUES ('invasor', 'x')$$,
  '42501', 'app não altera catálogo de tipos de parceiro');
SELECT pg_temp.espera_erro($$UPDATE servico_catalogo SET ativo = false$$,
  '42501', 'app não altera catálogo de serviços');
SELECT pg_temp.espera_erro($$DELETE FROM schema_migracao$$,
  '42501', 'app não mexe no controle de migrações');

-- ---------- Exclusão restrita ----------
SELECT pg_temp.espera_erro($$DELETE FROM usuario$$, '42501', 'app não apaga usuário (exclusão é lógica)');
SELECT pg_temp.espera_erro($$DELETE FROM consentimento$$, '42501', 'app não apaga consentimento');
SELECT pg_temp.espera_erro($$UPDATE sinal_risco SET severidade = 'baixa'$$, '42501', 'app não altera sinal de risco');

-- ---------- Uso normal ----------
SELECT pg_temp.aceita($$
  INSERT INTO usuario (keycloak_sub, email, perfil) VALUES (gen_random_uuid(), 'app@exemplo.invalid', 'tomador')$$,
  'app cadastra usuário');
SELECT pg_temp.aceita($$SELECT * FROM parceiros_proximos(-23.55, -46.63, 5000, 'guincho_leve')$$,
  'app executa parceiros_proximos');
SELECT pg_temp.aceita($$SELECT esta_bloqueado('email', pg_temp.hmac_teste('a@exemplo.invalid'))$$,
  'app executa esta_bloqueado');
SELECT pg_temp.aceita($$SELECT count(*) FROM vw_parceiro_posicao_valida$$,
  'app lê a view de posições válidas');

-- Fluxo completo do parceiro com os privilégios do app (os triggers rodam como o app).
SELECT pg_temp.aceita($$
  WITH p AS (
    INSERT INTO parceiro (id, tipo_pessoa, cnpj, nome, email_comercial, telefone_e164,
                          responsavel_nome, responsavel_cpf_cifrado, responsavel_cpf_hash)
    VALUES ('00000000-0000-4000-8000-0000000000f1', 'pj', '930000000001' || cnpj_dv('930000000001'),
            '[TESTE] Guincho via app', 'app-g@exemplo.invalid', '+5511900000400',
            '[TESTE] Responsável', '\x10', pg_temp.hmac_teste('39053344705'))
    RETURNING id)
  INSERT INTO parceiro_tipo (parceiro_id, tipo_codigo) SELECT id, 'guincho' FROM p$$,
  'app cadastra parceiro e tipo');
INSERT INTO parceiro_viatura (id, parceiro_id, placa, tipo)
VALUES ('00000000-0000-4000-8000-0000000000f2', '00000000-0000-4000-8000-0000000000f1', 'APP1A23', 'guincho_plataforma');
INSERT INTO parceiro_servico VALUES ('00000000-0000-4000-8000-0000000000f1', 'guincho_leve', true);
UPDATE parceiro SET status_credenciamento = 'aprovado' WHERE id = '00000000-0000-4000-8000-0000000000f1';
SELECT pg_temp.aceita($$
  INSERT INTO parceiro_posicao_atual (viatura_id, localizacao, precisao_m)
  VALUES ('00000000-0000-4000-8000-0000000000f2', ST_SetSRID(ST_MakePoint(-46.6339, -23.5503), 4326)::geography, 5)
  ON CONFLICT (viatura_id) DO UPDATE SET localizacao = EXCLUDED.localizacao$$,
  'app grava a posição da viatura (upsert)');
SELECT pg_temp.confere(
  (SELECT count(*) = 1 FROM parceiros_proximos(-23.5503, -46.6339, 1000, 'guincho_leve')),
  'app encontra o parceiro aprovado pela busca por proximidade');
