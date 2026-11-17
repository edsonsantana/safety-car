-- =====================================================================
-- SAFETY CAR — Modelo de dados v1 (PostgreSQL 16)
-- Escopo: identidade e cadastro do TOMADOR DO SERVIÇO e do PARCEIRO.
-- Fora do escopo desta versão: chamados, rastreamento (PostGIS), chat,
-- avaliações, pagamentos e seguros.
--
-- Decisões de projeto
--  * Senha, TOTP (Google/Microsoft Authenticator) e códigos de
--    recuperação ficam no provedor de identidade (Keycloak). Este banco
--    guarda apenas o vínculo (keycloak_sub) e espelhos de estado.
--  * Dados pessoais sensíveis (CPF, chave Pix) são cifrados na
--    aplicação; cpf_hash (HMAC com chave em cofre) permite busca e
--    unicidade sem expor o valor.
--  * Cada usuário tem um único perfil. Parceiros (empresas) são
--    entidades separadas, com vários usuários vinculados.
--  * Valores controlados usam text + CHECK, para facilitar migrações.
--  * Coluna atualizado_em é mantida pela aplicação (ou trigger futuro).
-- =====================================================================

CREATE EXTENSION IF NOT EXISTS citext;
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ---------------------------------------------------------------------
-- 1. NÚCLEO COMUM
-- ---------------------------------------------------------------------

CREATE TABLE endereco (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  cep           char(8) NOT NULL CHECK (cep ~ '^[0-9]{8}$'),
  logradouro    text NOT NULL,
  numero        text NOT NULL,
  complemento   text,
  bairro        text NOT NULL,
  municipio     text NOT NULL,
  municipio_ibge integer,
  uf            char(2) NOT NULL,
  criado_em     timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE usuario (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  keycloak_sub          uuid NOT NULL UNIQUE,
  email                 citext NOT NULL UNIQUE,
  celular_e164          text UNIQUE CHECK (celular_e164 ~ '^\+[1-9][0-9]{7,14}$'),
  perfil                text NOT NULL
                        CHECK (perfil IN ('tomador','parceiro','central','seguradora')),
  status                text NOT NULL DEFAULT 'pendente'
                        CHECK (status IN ('pendente','ativo','suspenso','bloqueado','excluido')),
  email_verificado_em   timestamptz,
  celular_verificado_em timestamptz,
  mfa_ativado_em        timestamptz,   -- espelho do estado no Keycloak
  ultimo_login_em       timestamptz,
  criado_em             timestamptz NOT NULL DEFAULT now(),
  atualizado_em         timestamptz NOT NULL DEFAULT now(),
  excluido_em           timestamptz
);

CREATE TABLE consentimento (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  usuario_id       uuid NOT NULL REFERENCES usuario(id),
  finalidade       text NOT NULL
                   CHECK (finalidade IN ('termos_uso','politica_privacidade',
                          'compartilhar_localizacao','contato_comercial',
                          'compartilhar_seguradora')),
  versao_documento text NOT NULL,
  concedido_em     timestamptz NOT NULL DEFAULT now(),
  revogado_em      timestamptz,
  ip               inet,
  user_agent       text
);
CREATE INDEX ix_consentimento_usuario ON consentimento (usuario_id, finalidade);

CREATE TABLE verificacao_identidade (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  usuario_id          uuid NOT NULL REFERENCES usuario(id),
  tipo                text NOT NULL
                      CHECK (tipo IN ('email','celular','cpf','documento_foto','selfie','cnh')),
  status              text NOT NULL DEFAULT 'pendente'
                      CHECK (status IN ('pendente','aprovada','rejeitada','expirada')),
  provedor            text,
  referencia_externa  text,
  motivo_rejeicao     text,
  solicitada_em       timestamptz NOT NULL DEFAULT now(),
  concluida_em        timestamptz,
  expira_em           timestamptz
);
CREATE INDEX ix_verificacao_usuario ON verificacao_identidade (usuario_id, tipo, status);

CREATE TABLE auditoria (
  id               bigserial PRIMARY KEY,
  ator_usuario_id  uuid REFERENCES usuario(id),
  acao             text NOT NULL,
  entidade         text NOT NULL,
  entidade_id      uuid,
  antes            jsonb,
  depois           jsonb,
  ip               inet,
  criado_em        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ix_auditoria_entidade ON auditoria (entidade, entidade_id, criado_em);
-- Tabela somente de inserção: revogar UPDATE e DELETE para o papel da aplicação.

-- ---------------------------------------------------------------------
-- 2. TOMADOR DO SERVIÇO
-- ---------------------------------------------------------------------

CREATE TABLE tomador (
  usuario_id        uuid PRIMARY KEY REFERENCES usuario(id),
  nome_completo     text NOT NULL,
  nome_social       text,
  cpf_cifrado       bytea,
  cpf_hash          bytea UNIQUE,
  data_nascimento   date,
  endereco_id       uuid REFERENCES endereco(id),
  -- 1 = e-mail + 2FA; 2 = celular e CPF validados; 3 = documento com foto
  nivel_verificacao smallint NOT NULL DEFAULT 1 CHECK (nivel_verificacao BETWEEN 1 AND 3),
  criado_em         timestamptz NOT NULL DEFAULT now(),
  atualizado_em     timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE veiculo (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tomador_id       uuid NOT NULL REFERENCES tomador(usuario_id),
  placa            char(7) NOT NULL CHECK (placa ~ '^[A-Z]{3}[0-9][A-Z0-9][0-9]{2}$'),
  apelido          text,
  marca            text NOT NULL,
  modelo           text NOT NULL,
  ano_fabricacao   smallint,
  ano_modelo       smallint,
  cor              text,
  categoria        text NOT NULL
                   CHECK (categoria IN ('passeio','utilitario','moto','van','caminhao','onibus')),
  ativo            boolean NOT NULL DEFAULT true,
  criado_em        timestamptz NOT NULL DEFAULT now(),
  UNIQUE (tomador_id, placa)
);

CREATE TABLE contato_emergencia (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tomador_id    uuid NOT NULL REFERENCES tomador(usuario_id),
  nome          text NOT NULL,
  celular_e164  text NOT NULL CHECK (celular_e164 ~ '^\+[1-9][0-9]{7,14}$'),
  parentesco    text,
  criado_em     timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------
-- 3. PARCEIRO REGISTRADO
-- ---------------------------------------------------------------------

CREATE TABLE parceiro (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tipo_pessoa           text NOT NULL CHECK (tipo_pessoa IN ('pj','mei','pf')),
  cnpj                  char(14) UNIQUE CHECK (cnpj ~ '^[0-9]{14}$'),
  cpf_cifrado           bytea,
  cpf_hash              bytea UNIQUE,
  razao_social          text NOT NULL,
  nome_fantasia         text,
  email_comercial       citext NOT NULL,
  telefone_e164         text NOT NULL CHECK (telefone_e164 ~ '^\+[1-9][0-9]{7,14}$'),
  endereco_id           uuid REFERENCES endereco(id),
  status_credenciamento text NOT NULL DEFAULT 'rascunho'
                        CHECK (status_credenciamento IN ('rascunho','em_analise','pendencia',
                               'aprovado','reprovado','suspenso','descredenciado')),
  motivo_status         text,
  aprovado_em           timestamptz,
  aprovado_por          uuid REFERENCES usuario(id),
  criado_em             timestamptz NOT NULL DEFAULT now(),
  atualizado_em         timestamptz NOT NULL DEFAULT now(),
  CHECK ( (tipo_pessoa = 'pf' AND cpf_hash IS NOT NULL)
       OR (tipo_pessoa IN ('pj','mei') AND cnpj IS NOT NULL) )
);

-- Um usuário pertence a, no máximo, um parceiro.
CREATE TABLE parceiro_membro (
  parceiro_id  uuid NOT NULL REFERENCES parceiro(id),
  usuario_id   uuid NOT NULL UNIQUE REFERENCES usuario(id),
  papel        text NOT NULL
               CHECK (papel IN ('proprietario','administrador','despachante','motorista_operador')),
  ativo        boolean NOT NULL DEFAULT true,
  desde        timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (parceiro_id, usuario_id)
);

CREATE TABLE servico_catalogo (
  codigo         text PRIMARY KEY,
  nome           text NOT NULL,
  exige_viatura  boolean NOT NULL DEFAULT false,
  ativo          boolean NOT NULL DEFAULT true
);

INSERT INTO servico_catalogo (codigo, nome, exige_viatura) VALUES
  ('guincho_leve',    'Guincho leve',                  true),
  ('guincho_pesado',  'Guincho pesado',                true),
  ('mecanica_movel',  'Mecânica móvel',                false),
  ('chaveiro',        'Chaveiro automotivo',           false),
  ('bateria',         'Carga e troca de bateria',      false),
  ('pneu',            'Troca de pneu',                 false),
  ('combustivel',     'Pane seca / combustível',       false);

CREATE TABLE parceiro_servico (
  parceiro_id    uuid NOT NULL REFERENCES parceiro(id),
  servico_codigo text NOT NULL REFERENCES servico_catalogo(codigo),
  ativo          boolean NOT NULL DEFAULT true,
  PRIMARY KEY (parceiro_id, servico_codigo)
);

CREATE TABLE parceiro_viatura (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  parceiro_id    uuid NOT NULL REFERENCES parceiro(id),
  placa          char(7) NOT NULL CHECK (placa ~ '^[A-Z]{3}[0-9][A-Z0-9][0-9]{2}$'),
  tipo           text NOT NULL
                 CHECK (tipo IN ('guincho_plataforma','guincho_asa_delta','guincho_pesado',
                        'utilitario_mecanico','moto_socorro','outro')),
  marca_modelo   text,
  ano            smallint,
  capacidade_kg  integer CHECK (capacidade_kg > 0),
  ativa          boolean NOT NULL DEFAULT true,
  criado_em      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (parceiro_id, placa)
);

CREATE TABLE parceiro_area_atuacao (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  parceiro_id     uuid NOT NULL REFERENCES parceiro(id),
  uf              char(2) NOT NULL,
  municipio_ibge  integer,           -- nulo = estado inteiro
  UNIQUE (parceiro_id, uf, municipio_ibge)
);

-- usuario_id: documentos pessoais (ex.: CNH do motorista operador)
-- viatura_id: documentos da viatura (ex.: CRLV)
CREATE TABLE parceiro_documento (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  parceiro_id      uuid NOT NULL REFERENCES parceiro(id),
  usuario_id       uuid REFERENCES usuario(id),
  viatura_id       uuid REFERENCES parceiro_viatura(id),
  tipo             text NOT NULL
                   CHECK (tipo IN ('contrato_social','cartao_cnpj','comprovante_endereco',
                          'cnh','crlv','seguro_rcf','rntrc','alvara')),
  arquivo_ref      text NOT NULL,      -- chave no armazenamento de objetos
  sha256           char(64) NOT NULL,
  validade         date,
  status           text NOT NULL DEFAULT 'enviado'
                   CHECK (status IN ('enviado','aprovado','rejeitado','vencido')),
  motivo_rejeicao  text,
  revisado_por     uuid REFERENCES usuario(id),
  revisado_em      timestamptz,
  enviado_em       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ix_parceiro_documento ON parceiro_documento (parceiro_id, tipo, status);
CREATE INDEX ix_parceiro_doc_validade ON parceiro_documento (validade) WHERE status = 'aprovado';

-- Estrutura mínima para repasses futuros (pagamentos fora do escopo da v1).
CREATE TABLE parceiro_conta_recebimento (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  parceiro_id       uuid NOT NULL REFERENCES parceiro(id),
  tipo_chave_pix    text NOT NULL CHECK (tipo_chave_pix IN ('cpf','cnpj','email','celular','aleatoria')),
  chave_pix_cifrada bytea NOT NULL,
  verificada_em     timestamptz,
  ativa             boolean NOT NULL DEFAULT true,
  criado_em         timestamptz NOT NULL DEFAULT now()
);
