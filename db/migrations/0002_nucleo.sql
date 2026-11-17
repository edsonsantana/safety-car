-- 0002 — Núcleo: domínios, funções utilitárias, endereço, usuário, consentimento,
--        verificação de identidade e auditoria.
--
-- Códigos de erro próprios (SQLSTATE classe SC), usados por triggers de regra:
--   SC001 perfil do usuário incompatível com o vínculo
--   SC010 auditoria é somente de inserção
-- (demais códigos nas migrações seguintes; lista completa em docs/BANCO_DE_DADOS.md)

-- ---------------------------------------------------------------------
-- Domínios de formato (reutilizados em todas as tabelas)
-- ---------------------------------------------------------------------

-- CEP: 8 dígitos, sem máscara.
CREATE DOMAIN dom_cep AS text
  CHECK (VALUE ~ '^[0-9]{8}$');

-- UF: uma das 27 unidades da federação.
CREATE DOMAIN dom_uf AS text
  CHECK (VALUE IN ('AC','AL','AP','AM','BA','CE','DF','ES','GO','MA','MT','MS','MG','PA',
                   'PB','PR','PE','PI','RJ','RN','RS','RO','RR','SC','SP','SE','TO'));

-- Código IBGE do município: 7 dígitos (os 2 primeiros são o código da UF).
CREATE DOMAIN dom_municipio_ibge AS integer
  CHECK (VALUE BETWEEN 1000000 AND 9999999);

-- Telefone em E.164: "+", código do país e número; 8 a 15 dígitos no total.
CREATE DOMAIN dom_e164 AS text
  CHECK (VALUE ~ '^\+[1-9][0-9]{7,14}$');

-- Placa: padrão antigo AAA9999 ou Mercosul AAA9A99 (maiúsculas, sem hífen).
CREATE DOMAIN dom_placa AS text
  CHECK (VALUE ~ '^[A-Z]{3}[0-9][A-Z0-9][0-9]{2}$');

-- HMAC-SHA256 (32 bytes) calculado pela aplicação com chave fora do repositório.
CREATE DOMAIN dom_hmac AS bytea
  CHECK (octet_length(VALUE) = 32);

-- Código numérico IBGE da UF (usado para conferir município x UF).
CREATE FUNCTION uf_codigo_ibge(p_uf text) RETURNS smallint
LANGUAGE sql IMMUTABLE STRICT AS $$
  SELECT CASE p_uf
    WHEN 'RO' THEN 11 WHEN 'AC' THEN 12 WHEN 'AM' THEN 13 WHEN 'RR' THEN 14 WHEN 'PA' THEN 15
    WHEN 'AP' THEN 16 WHEN 'TO' THEN 17 WHEN 'MA' THEN 21 WHEN 'PI' THEN 22 WHEN 'CE' THEN 23
    WHEN 'RN' THEN 24 WHEN 'PB' THEN 25 WHEN 'PE' THEN 26 WHEN 'AL' THEN 27 WHEN 'SE' THEN 28
    WHEN 'BA' THEN 29 WHEN 'MG' THEN 31 WHEN 'ES' THEN 32 WHEN 'RJ' THEN 33 WHEN 'SP' THEN 35
    WHEN 'PR' THEN 41 WHEN 'SC' THEN 42 WHEN 'RS' THEN 43 WHEN 'MS' THEN 50 WHEN 'MT' THEN 51
    WHEN 'GO' THEN 52 WHEN 'DF' THEN 53
  END::smallint
$$;

-- CNPJ: dígitos verificadores (módulo 11) a partir dos 12 primeiros caracteres.
-- Vale para o CNPJ numérico e para o alfanumérico (emitido a partir de jul/2026):
-- o valor de cada caractere é o seu código ASCII menos 48 ('0'..'9' = 0..9, 'A' = 17 ... 'Z' = 42).
CREATE FUNCTION cnpj_dv(p_base text) RETURNS text
LANGUAGE plpgsql IMMUTABLE STRICT AS $$
DECLARE
  pesos  int[] := ARRAY[6,5,4,3,2,9,8,7,6,5,4,3,2];
  soma   int;
  resto  int;
  dv1    int;
  dv2    int;
BEGIN
  IF p_base !~ '^[0-9A-Z]{12}$' THEN
    RETURN NULL;
  END IF;
  soma := 0;
  FOR i IN 1..12 LOOP
    soma := soma + (ascii(substr(p_base, i, 1)) - 48) * pesos[i + 1];
  END LOOP;
  resto := soma % 11;
  dv1 := CASE WHEN resto < 2 THEN 0 ELSE 11 - resto END;

  soma := dv1 * pesos[13];
  FOR i IN 1..12 LOOP
    soma := soma + (ascii(substr(p_base, i, 1)) - 48) * pesos[i];
  END LOOP;
  resto := soma % 11;
  dv2 := CASE WHEN resto < 2 THEN 0 ELSE 11 - resto END;

  RETURN dv1::text || dv2::text;
END $$;

CREATE FUNCTION cnpj_valido(p_cnpj text) RETURNS boolean
LANGUAGE sql IMMUTABLE STRICT AS $$
  SELECT p_cnpj ~ '^[0-9A-Z]{12}[0-9]{2}$'
     AND p_cnpj !~ '^(.)\1{13}$'               -- rejeita 00000000000000, 11111111111111...
     AND cnpj_dv(substr(p_cnpj, 1, 12)) = substr(p_cnpj, 13, 2)
$$;

-- CNPJ: 14 caracteres sem máscara, maiúsculas, com DV válido.
CREATE DOMAIN dom_cnpj AS text
  CHECK (cnpj_valido(VALUE));

-- ---------------------------------------------------------------------
-- Triggers genéricos
-- ---------------------------------------------------------------------

-- Mantém atualizado_em em toda tabela mutável.
CREATE FUNCTION definir_atualizado_em() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  NEW.atualizado_em := now();
  RETURN NEW;
END $$;

-- Exige que o usuário referenciado tenha o perfil esperado.
-- Uso: EXECUTE FUNCTION exige_perfil('<perfil>', '<coluna com o usuario_id>')
CREATE FUNCTION exige_perfil() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  v_perfil_esperado text := TG_ARGV[0];
  v_coluna          text := coalesce(TG_ARGV[1], 'usuario_id');
  v_usuario_id      uuid := (to_jsonb(NEW) ->> v_coluna)::uuid;
  v_perfil          text;
BEGIN
  IF v_usuario_id IS NULL THEN
    RETURN NEW;
  END IF;
  SELECT perfil INTO v_perfil FROM usuario WHERE id = v_usuario_id;
  IF v_perfil IS DISTINCT FROM v_perfil_esperado THEN
    RAISE EXCEPTION 'usuário % tem perfil "%", mas %.% exige perfil "%"',
      v_usuario_id, v_perfil, TG_TABLE_NAME, v_coluna, v_perfil_esperado
      USING ERRCODE = 'SC001';
  END IF;
  RETURN NEW;
END $$;

-- ---------------------------------------------------------------------
-- Endereço
-- ---------------------------------------------------------------------

CREATE TABLE endereco (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  cep            dom_cep NOT NULL,
  logradouro     text NOT NULL,
  numero         text NOT NULL,
  complemento    text,
  bairro         text NOT NULL,
  municipio      text NOT NULL,
  municipio_ibge dom_municipio_ibge,
  uf             dom_uf NOT NULL,
  criado_em      timestamptz NOT NULL DEFAULT now(),
  atualizado_em  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ck_endereco_municipio_da_uf
    CHECK (municipio_ibge IS NULL OR municipio_ibge / 100000 = uf_codigo_ibge(uf))
);
CREATE TRIGGER tg_endereco_atualizado_em BEFORE UPDATE ON endereco
  FOR EACH ROW EXECUTE FUNCTION definir_atualizado_em();

-- ---------------------------------------------------------------------
-- Usuário (identidade). Senha, TOTP e códigos de recuperação ficam no Keycloak.
-- ---------------------------------------------------------------------

CREATE TABLE usuario (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  keycloak_sub          uuid NOT NULL UNIQUE,
  email                 citext NOT NULL UNIQUE,
  celular_e164          dom_e164 UNIQUE,
  perfil                text NOT NULL
                        CHECK (perfil IN ('tomador','parceiro','central')),
  status                text NOT NULL DEFAULT 'pendente'
                        CHECK (status IN ('pendente','ativo','suspenso','bloqueado','excluido')),
  email_verificado_em   timestamptz,
  celular_verificado_em timestamptz,
  mfa_ativado_em        timestamptz,   -- espelho do estado no Keycloak
  ultimo_login_em       timestamptz,
  criado_em             timestamptz NOT NULL DEFAULT now(),
  atualizado_em         timestamptz NOT NULL DEFAULT now(),
  excluido_em           timestamptz,
  CONSTRAINT ck_usuario_excluido CHECK ((status = 'excluido') = (excluido_em IS NOT NULL))
);
CREATE TRIGGER tg_usuario_atualizado_em BEFORE UPDATE ON usuario
  FOR EACH ROW EXECUTE FUNCTION definir_atualizado_em();

-- ---------------------------------------------------------------------
-- Consentimento (LGPD): histórico de concessões e revogações por finalidade.
-- ---------------------------------------------------------------------

CREATE TABLE consentimento (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  usuario_id       uuid NOT NULL REFERENCES usuario(id),
  finalidade       text NOT NULL
                   CHECK (finalidade IN ('termos_uso','politica_privacidade',
                          'compartilhar_localizacao','contato_comercial',
                          'compartilhar_parceiro_seguros')),
  versao_documento text NOT NULL,
  concedido_em     timestamptz NOT NULL DEFAULT now(),
  revogado_em      timestamptz,
  ip               inet,
  user_agent       text,
  CONSTRAINT ck_consentimento_revogacao CHECK (revogado_em IS NULL OR revogado_em >= concedido_em)
);
-- Consulta prevista: "o usuário X tem consentimento vigente para a finalidade Y?"
CREATE INDEX ix_consentimento_usuario ON consentimento (usuario_id, finalidade);

-- ---------------------------------------------------------------------
-- Verificação de identidade (e-mail, celular, CPF, documento, selfie, CNH)
-- ---------------------------------------------------------------------

CREATE TABLE verificacao_identidade (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  usuario_id         uuid NOT NULL REFERENCES usuario(id),
  tipo               text NOT NULL
                     CHECK (tipo IN ('email','celular','cpf','documento_foto','selfie','cnh')),
  status             text NOT NULL DEFAULT 'pendente'
                     CHECK (status IN ('pendente','aprovada','rejeitada','expirada')),
  provedor           text,
  referencia_externa text,
  motivo_rejeicao    text,
  solicitada_em      timestamptz NOT NULL DEFAULT now(),
  concluida_em       timestamptz,
  expira_em          timestamptz
);
-- Consulta prevista: "qual o estado de cada verificação do usuário X?" (cálculo do nível)
CREATE INDEX ix_verificacao_usuario ON verificacao_identidade (usuario_id, tipo, status);

-- ---------------------------------------------------------------------
-- Auditoria: somente inserção (garantido por privilégio na 0007 E por trigger aqui).
-- ---------------------------------------------------------------------

CREATE TABLE auditoria (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  ator_usuario_id uuid REFERENCES usuario(id),
  acao            text NOT NULL,
  entidade        text NOT NULL,
  entidade_id     uuid,
  antes           jsonb,
  depois          jsonb,
  ip              inet,
  criado_em       timestamptz NOT NULL DEFAULT now()
);
-- Consulta prevista: "histórico da entidade X em ordem cronológica"
CREATE INDEX ix_auditoria_entidade ON auditoria (entidade, entidade_id, criado_em);

CREATE FUNCTION auditoria_somente_insercao() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'auditoria é somente de inserção: % não é permitido', TG_OP
    USING ERRCODE = 'SC010';
END $$;

-- Vale inclusive para o dono da tabela e para superusuário.
CREATE TRIGGER tg_auditoria_sem_alteracao BEFORE UPDATE OR DELETE ON auditoria
  FOR EACH ROW EXECUTE FUNCTION auditoria_somente_insercao();
CREATE TRIGGER tg_auditoria_sem_truncate BEFORE TRUNCATE ON auditoria
  FOR EACH STATEMENT EXECUTE FUNCTION auditoria_somente_insercao();
