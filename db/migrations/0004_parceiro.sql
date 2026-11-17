-- 0004 — Parceiro: entidade única (empresa ou profissional) com nome e tipificação.
-- Cobre o que na v8 era Prestador e Parceiro de Seguros.
--
-- Regras por tipo (triggers; erros com SQLSTATE próprio):
--   SC002 viatura só para parceiro com tipo que PERMITE viatura
--   SC003 aprovação de parceiro de tipo que exige Susep sem registro_susep aprovado
--   SC004 aprovação de parceiro de tipo que EXIGE viatura sem viatura ativa
--   SC005 serviço de socorro só para parceiro de tipo de assistência rodoviária
--   SC006 remoção de tipo que deixaria viatura/serviço sem tipo que os sustente
--   SC007 aprovação de parceiro sem nenhum tipo
--   SC008 vínculo com tipo de parceiro inativo
--   SC001 (da 0002) perfil incompatível: membro precisa ser "parceiro"; aprovador/revisor, "central"

-- ---------------------------------------------------------------------
-- Catálogo de tipos de parceiro
-- ---------------------------------------------------------------------

CREATE TABLE tipo_parceiro (
  codigo                 text PRIMARY KEY CHECK (codigo ~ '^[a-z][a-z0-9_]*$'),
  nome                   text NOT NULL,
  exige_viatura          boolean NOT NULL DEFAULT false,  -- só é aprovado com viatura ativa
  permite_viatura        boolean NOT NULL DEFAULT false,  -- pode cadastrar viatura (e ter posição)
  exige_registro_susep   boolean NOT NULL DEFAULT false,  -- só é aprovado com registro Susep aprovado
  assistencia_rodoviaria boolean NOT NULL DEFAULT false,  -- presta socorro: serviços, área, busca
  ativo                  boolean NOT NULL DEFAULT true,
  CONSTRAINT ck_tipo_exige_implica_permite CHECK (NOT exige_viatura OR permite_viatura)
);

INSERT INTO tipo_parceiro
  (codigo, nome, exige_viatura, permite_viatura, exige_registro_susep, assistencia_rodoviaria) VALUES
  ('guincho',  'Guincho',  true,  true,  false, true),
  ('mecanica', 'Mecânica', false, true,  false, true),
  ('chaveiro', 'Chaveiro', false, true,  false, true),
  ('seguros',  'Seguros',  false, false, true,  false);

-- ---------------------------------------------------------------------
-- Parceiro
-- ---------------------------------------------------------------------

CREATE TABLE parceiro (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tipo_pessoa           text NOT NULL CHECK (tipo_pessoa IN ('pj','mei','pf')),
  cnpj                  dom_cnpj UNIQUE,
  cpf_cifrado           bytea,
  cpf_hash              dom_hmac UNIQUE,
  nome                  text NOT NULL,   -- razão social (PJ/MEI) ou nome completo (PF)
  nome_fantasia         text,
  email_comercial       citext NOT NULL,
  telefone_e164         dom_e164 NOT NULL,
  endereco_id           uuid REFERENCES endereco(id),
  status_credenciamento text NOT NULL DEFAULT 'rascunho'
                        CHECK (status_credenciamento IN ('rascunho','em_analise','pendencia',
                               'aprovado','reprovado','suspenso','descredenciado')),
  motivo_status         text,
  aprovado_em           timestamptz,
  aprovado_por          uuid REFERENCES usuario(id),
  criado_em             timestamptz NOT NULL DEFAULT now(),
  atualizado_em         timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ck_parceiro_cpf_par CHECK ((cpf_cifrado IS NULL) = (cpf_hash IS NULL)),
  CONSTRAINT ck_parceiro_documento_pessoa CHECK (
       (tipo_pessoa = 'pf'          AND cpf_hash IS NOT NULL)
    OR (tipo_pessoa IN ('pj','mei') AND cnpj     IS NOT NULL))
);
CREATE TRIGGER tg_parceiro_atualizado_em BEFORE UPDATE ON parceiro
  FOR EACH ROW EXECUTE FUNCTION definir_atualizado_em();
CREATE TRIGGER tg_parceiro_aprovador_central BEFORE INSERT OR UPDATE OF aprovado_por ON parceiro
  FOR EACH ROW EXECUTE FUNCTION exige_perfil('central', 'aprovado_por');

-- Tipos do parceiro (N:N)
CREATE TABLE parceiro_tipo (
  parceiro_id  uuid NOT NULL REFERENCES parceiro(id),
  tipo_codigo  text NOT NULL REFERENCES tipo_parceiro(codigo),
  criado_em    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (parceiro_id, tipo_codigo)
);

-- Funções de apoio às regras por tipo (consideram só tipos ativos).
CREATE FUNCTION parceiro_tem_tipo_com(p_parceiro_id uuid, p_atributo text) RETURNS boolean
LANGUAGE sql STABLE AS $$
  SELECT EXISTS (
    SELECT 1
      FROM parceiro_tipo pt
      JOIN tipo_parceiro tp ON tp.codigo = pt.tipo_codigo
     WHERE pt.parceiro_id = p_parceiro_id
       AND tp.ativo
       AND CASE p_atributo
             WHEN 'exige_viatura'          THEN tp.exige_viatura
             WHEN 'permite_viatura'        THEN tp.permite_viatura
             WHEN 'exige_registro_susep'   THEN tp.exige_registro_susep
             WHEN 'assistencia_rodoviaria' THEN tp.assistencia_rodoviaria
             WHEN 'qualquer'               THEN true
           END)
$$;

CREATE FUNCTION parceiro_tipo_ativo() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM tipo_parceiro WHERE codigo = NEW.tipo_codigo AND ativo) THEN
    RAISE EXCEPTION 'tipo de parceiro "%" está inativo', NEW.tipo_codigo USING ERRCODE = 'SC008';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER tg_parceiro_tipo_ativo BEFORE INSERT OR UPDATE OF tipo_codigo ON parceiro_tipo
  FOR EACH ROW EXECUTE FUNCTION parceiro_tipo_ativo();

-- ---------------------------------------------------------------------
-- Membros (usuários do parceiro). Um usuário pertence a, no máximo, um parceiro.
-- ---------------------------------------------------------------------

CREATE TABLE parceiro_membro (
  parceiro_id uuid NOT NULL REFERENCES parceiro(id),
  usuario_id  uuid NOT NULL UNIQUE REFERENCES usuario(id),
  papel       text NOT NULL
              CHECK (papel IN ('proprietario','administrador','despachante','motorista_operador')),
  ativo       boolean NOT NULL DEFAULT true,
  desde       timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (parceiro_id, usuario_id)
);
CREATE TRIGGER tg_parceiro_membro_perfil BEFORE INSERT OR UPDATE OF usuario_id ON parceiro_membro
  FOR EACH ROW EXECUTE FUNCTION exige_perfil('parceiro', 'usuario_id');

-- Usuário já vinculado como tomador ou membro de parceiro não troca de perfil.
CREATE FUNCTION usuario_perfil_vinculado() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM tomador WHERE usuario_id = NEW.id)
     OR EXISTS (SELECT 1 FROM parceiro_membro WHERE usuario_id = NEW.id) THEN
    RAISE EXCEPTION 'usuário % já tem vínculo como "%"; o perfil não pode mudar para "%"',
      NEW.id, OLD.perfil, NEW.perfil USING ERRCODE = 'SC001';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER tg_usuario_perfil_vinculado BEFORE UPDATE OF perfil ON usuario
  FOR EACH ROW WHEN (OLD.perfil IS DISTINCT FROM NEW.perfil)
  EXECUTE FUNCTION usuario_perfil_vinculado();

-- ---------------------------------------------------------------------
-- Serviços de socorro
-- ---------------------------------------------------------------------

CREATE TABLE servico_catalogo (
  codigo        text PRIMARY KEY CHECK (codigo ~ '^[a-z][a-z0-9_]*$'),
  nome          text NOT NULL,
  exige_viatura boolean NOT NULL DEFAULT false,
  ativo         boolean NOT NULL DEFAULT true
);

INSERT INTO servico_catalogo (codigo, nome, exige_viatura) VALUES
  ('guincho_leve',   'Guincho leve',             true),
  ('guincho_pesado', 'Guincho pesado',           true),
  ('mecanica_movel', 'Mecânica móvel',           false),
  ('chaveiro',       'Chaveiro automotivo',      false),
  ('bateria',        'Carga e troca de bateria', false),
  ('pneu',           'Troca de pneu',            false),
  ('combustivel',    'Pane seca / combustível',  false);

-- PK também atende "o parceiro X oferece o serviço Y?" (busca por proximidade).
CREATE TABLE parceiro_servico (
  parceiro_id    uuid NOT NULL REFERENCES parceiro(id),
  servico_codigo text NOT NULL REFERENCES servico_catalogo(codigo),
  ativo          boolean NOT NULL DEFAULT true,
  PRIMARY KEY (parceiro_id, servico_codigo)
);

CREATE FUNCTION exige_parceiro_assistencia() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NOT parceiro_tem_tipo_com(NEW.parceiro_id, 'assistencia_rodoviaria') THEN
    RAISE EXCEPTION 'parceiro % não tem tipo de assistência rodoviária; % não se aplica',
      NEW.parceiro_id, TG_TABLE_NAME USING ERRCODE = 'SC005';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER tg_parceiro_servico_assistencia BEFORE INSERT OR UPDATE OF parceiro_id ON parceiro_servico
  FOR EACH ROW EXECUTE FUNCTION exige_parceiro_assistencia();

-- ---------------------------------------------------------------------
-- Viaturas
-- ---------------------------------------------------------------------

CREATE TABLE parceiro_viatura (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  parceiro_id   uuid NOT NULL REFERENCES parceiro(id),
  placa         dom_placa NOT NULL,
  tipo          text NOT NULL
                CHECK (tipo IN ('guincho_plataforma','guincho_asa_delta','guincho_pesado',
                       'utilitario_mecanico','moto_socorro','outro')),
  marca_modelo  text,
  ano           smallint,
  capacidade_kg integer CHECK (capacidade_kg > 0),
  ativa         boolean NOT NULL DEFAULT true,
  criado_em     timestamptz NOT NULL DEFAULT now(),
  atualizado_em timestamptz NOT NULL DEFAULT now(),
  -- Também serve de índice para "viaturas do parceiro X".
  CONSTRAINT uq_viatura_parceiro_placa UNIQUE (parceiro_id, placa),
  -- Alvo da FK composta de parceiro_documento (documento da viatura é do mesmo parceiro).
  CONSTRAINT uq_viatura_id_parceiro UNIQUE (id, parceiro_id)
);
CREATE TRIGGER tg_parceiro_viatura_atualizado_em BEFORE UPDATE ON parceiro_viatura
  FOR EACH ROW EXECUTE FUNCTION definir_atualizado_em();

CREATE FUNCTION viatura_permitida() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.ativa AND NOT parceiro_tem_tipo_com(NEW.parceiro_id, 'permite_viatura') THEN
    RAISE EXCEPTION 'parceiro % não tem tipo que permita viatura', NEW.parceiro_id
      USING ERRCODE = 'SC002';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER tg_parceiro_viatura_permitida BEFORE INSERT OR UPDATE OF parceiro_id, ativa ON parceiro_viatura
  FOR EACH ROW EXECUTE FUNCTION viatura_permitida();

-- Remover/trocar um tipo não pode deixar viatura ativa ou serviço sem tipo que os sustente.
-- (Redefinida na 0005 para incluir a área de atuação.)
CREATE FUNCTION parceiro_tipo_remocao() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM parceiro_viatura WHERE parceiro_id = OLD.parceiro_id AND ativa)
     AND NOT parceiro_tem_tipo_com(OLD.parceiro_id, 'permite_viatura') THEN
    RAISE EXCEPTION 'parceiro % tem viatura ativa e ficaria sem tipo que permita viatura', OLD.parceiro_id
      USING ERRCODE = 'SC006';
  END IF;
  IF EXISTS (SELECT 1 FROM parceiro_servico WHERE parceiro_id = OLD.parceiro_id)
     AND NOT parceiro_tem_tipo_com(OLD.parceiro_id, 'assistencia_rodoviaria') THEN
    RAISE EXCEPTION 'parceiro % tem serviços de socorro e ficaria sem tipo de assistência', OLD.parceiro_id
      USING ERRCODE = 'SC006';
  END IF;
  RETURN NULL;
END $$;
CREATE TRIGGER tg_parceiro_tipo_remocao AFTER DELETE OR UPDATE ON parceiro_tipo
  FOR EACH ROW EXECUTE FUNCTION parceiro_tipo_remocao();

-- ---------------------------------------------------------------------
-- Documentos
--   usuario_id: documento pessoal de um membro (ex.: CNH do motorista operador)
--   viatura_id: documento da viatura (ex.: CRLV)
-- ---------------------------------------------------------------------

CREATE TABLE parceiro_documento (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  parceiro_id     uuid NOT NULL REFERENCES parceiro(id),
  usuario_id      uuid,
  viatura_id      uuid,
  tipo            text NOT NULL
                  CHECK (tipo IN ('contrato_social','cartao_cnpj','comprovante_endereco',
                         'cnh','crlv','seguro_rcf','rntrc','alvara','registro_susep')),
  arquivo_ref     text NOT NULL,      -- chave no armazenamento de objetos (o arquivo não fica no banco)
  sha256          char(64) NOT NULL CHECK (sha256 ~ '^[0-9a-f]{64}$'),
  validade        date,
  status          text NOT NULL DEFAULT 'enviado'
                  CHECK (status IN ('enviado','aprovado','rejeitado','vencido')),
  motivo_rejeicao text,
  revisado_por    uuid REFERENCES usuario(id),
  revisado_em     timestamptz,
  enviado_em      timestamptz NOT NULL DEFAULT now(),
  atualizado_em   timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT fk_documento_membro  FOREIGN KEY (parceiro_id, usuario_id)
    REFERENCES parceiro_membro (parceiro_id, usuario_id),
  CONSTRAINT fk_documento_viatura FOREIGN KEY (viatura_id, parceiro_id)
    REFERENCES parceiro_viatura (id, parceiro_id)
);
-- Consulta prevista: "documentos do parceiro X por tipo/status" (análise e regra de aprovação)
CREATE INDEX ix_parceiro_documento ON parceiro_documento (parceiro_id, tipo, status);
-- Consulta prevista: "documentos aprovados que vencem até a data D" (rotina de vencimento)
CREATE INDEX ix_parceiro_doc_validade ON parceiro_documento (validade) WHERE status = 'aprovado';
CREATE TRIGGER tg_parceiro_documento_atualizado_em BEFORE UPDATE ON parceiro_documento
  FOR EACH ROW EXECUTE FUNCTION definir_atualizado_em();
CREATE TRIGGER tg_parceiro_documento_revisor_central BEFORE INSERT OR UPDATE OF revisado_por ON parceiro_documento
  FOR EACH ROW EXECUTE FUNCTION exige_perfil('central', 'revisado_por');

-- ---------------------------------------------------------------------
-- Aprovação do credenciamento: requisitos por tipo
-- ---------------------------------------------------------------------

CREATE FUNCTION parceiro_aprovacao() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.status_credenciamento <> 'aprovado'
     OR (TG_OP = 'UPDATE' AND OLD.status_credenciamento = 'aprovado') THEN
    RETURN NEW;
  END IF;

  IF NOT parceiro_tem_tipo_com(NEW.id, 'qualquer') THEN
    RAISE EXCEPTION 'parceiro % não pode ser aprovado sem nenhum tipo', NEW.id
      USING ERRCODE = 'SC007';
  END IF;

  IF parceiro_tem_tipo_com(NEW.id, 'exige_registro_susep')
     AND NOT EXISTS (SELECT 1 FROM parceiro_documento
                      WHERE parceiro_id = NEW.id AND tipo = 'registro_susep' AND status = 'aprovado') THEN
    RAISE EXCEPTION 'parceiro % tem tipo que exige registro Susep e não há registro_susep aprovado', NEW.id
      USING ERRCODE = 'SC003';
  END IF;

  IF parceiro_tem_tipo_com(NEW.id, 'exige_viatura')
     AND NOT EXISTS (SELECT 1 FROM parceiro_viatura WHERE parceiro_id = NEW.id AND ativa) THEN
    RAISE EXCEPTION 'parceiro % tem tipo que exige viatura e não há viatura ativa', NEW.id
      USING ERRCODE = 'SC004';
  END IF;

  RETURN NEW;
END $$;
CREATE TRIGGER tg_parceiro_aprovacao BEFORE INSERT OR UPDATE OF status_credenciamento ON parceiro
  FOR EACH ROW EXECUTE FUNCTION parceiro_aprovacao();

-- ---------------------------------------------------------------------
-- Conta de recebimento (estrutura mínima para repasses futuros)
-- ---------------------------------------------------------------------

CREATE TABLE parceiro_conta_recebimento (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  parceiro_id       uuid NOT NULL REFERENCES parceiro(id),
  tipo_chave_pix    text NOT NULL CHECK (tipo_chave_pix IN ('cpf','cnpj','email','celular','aleatoria')),
  chave_pix_cifrada bytea NOT NULL,   -- cifrada pela aplicação
  verificada_em     timestamptz,
  ativa             boolean NOT NULL DEFAULT true,
  criado_em         timestamptz NOT NULL DEFAULT now(),
  atualizado_em     timestamptz NOT NULL DEFAULT now()
);
-- Consulta prevista: "contas de recebimento do parceiro X"
CREATE INDEX ix_conta_recebimento_parceiro ON parceiro_conta_recebimento (parceiro_id);
CREATE TRIGGER tg_conta_recebimento_atualizado_em BEFORE UPDATE ON parceiro_conta_recebimento
  FOR EACH ROW EXECUTE FUNCTION definir_atualizado_em();
