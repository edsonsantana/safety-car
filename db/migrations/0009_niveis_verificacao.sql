-- 0009 — Níveis de verificação: catálogo, requisitos por nível e perfil, nível mínimo por serviço,
--        nível atual de tomador e parceiro com histórico. Também cria a auditoria automática das
--        tabelas de parametrização (usada pelas migrações 0010 e 0011).
--
-- Só estrutura aqui. Os valores de negócio (requisitos de cada nível e nível mínimo por serviço)
-- entram na 0012, marcados como "a_definir" ou proposta.
--
-- Códigos de erro novos:
--   SC011 nível atual de tomador/parceiro alterado fora do histórico
--   SC013 parâmetro "a definir" ou inexistente (nunca tratar como valor válido)
--   SC015 requisito de verificação incompatível com o perfil
--   SC010 (da 0002) passa a valer também para outras tabelas somente de inserção

-- ---------------------------------------------------------------------
-- Auditoria: papel do banco que fez a alteração
-- ---------------------------------------------------------------------

-- Nulo nas linhas anteriores à 0009 (papel desconhecido). Daqui em diante é sempre preenchida
-- pelo trigger abaixo com o papel real, ignorando o valor enviado.
ALTER TABLE auditoria ADD COLUMN papel_bd text;
ALTER TABLE auditoria ALTER COLUMN papel_bd SET DEFAULT current_user;

CREATE FUNCTION auditoria_papel_bd() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  NEW.papel_bd := current_user;
  RETURN NEW;
END $$;
CREATE TRIGGER tg_auditoria_papel_bd BEFORE INSERT ON auditoria
  FOR EACH ROW EXECUTE FUNCTION auditoria_papel_bd();

-- ---------------------------------------------------------------------
-- Auditoria automática das tabelas de parametrização
-- ---------------------------------------------------------------------

-- Grava toda inserção, alteração e exclusão em "auditoria".
-- Ator: o usuário da aplicação informado em safetycar.ator_usuario_id (SET LOCAL), se houver;
-- nulo = sistema/migração (o papel do banco fica em auditoria.papel_bd).
CREATE FUNCTION auditar_parametrizacao() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  v_antes  jsonb := CASE WHEN TG_OP IN ('UPDATE','DELETE') THEN to_jsonb(OLD) END;
  v_depois jsonb := CASE WHEN TG_OP IN ('INSERT','UPDATE') THEN to_jsonb(NEW) END;
  v_id     text  := coalesce(v_depois, v_antes) ->> 'id';
BEGIN
  INSERT INTO auditoria (ator_usuario_id, acao, entidade, entidade_id, antes, depois)
  VALUES (nullif(current_setting('safetycar.ator_usuario_id', true), '')::uuid,
          'parametrizacao_' || lower(TG_OP),
          TG_TABLE_NAME,
          CASE WHEN v_id ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
               THEN v_id::uuid END,
          v_antes, v_depois);
  RETURN NULL;
END $$;

-- TRUNCATE não passa pelo trigger de linha, então não seria auditado: é bloqueado.
CREATE FUNCTION bloquear_truncate() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'TRUNCATE não é permitido em % (alterações são auditadas linha a linha)', TG_TABLE_NAME
    USING ERRCODE = 'SC010';
END $$;

-- Tabela somente de inserção (histórico). Mesmo código da auditoria (SC010).
CREATE FUNCTION somente_insercao() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION '% é somente de inserção: % não é permitido', TG_TABLE_NAME, TG_OP
    USING ERRCODE = 'SC010';
END $$;

-- ---------------------------------------------------------------------
-- Catálogo de níveis e de requisitos (estrutura)
-- ---------------------------------------------------------------------

CREATE TABLE nivel_verificacao (
  nivel     smallint PRIMARY KEY CHECK (nivel BETWEEN 1 AND 3),
  nome      text NOT NULL,
  descricao text
);
CREATE TRIGGER tg_nivel_verificacao_auditoria AFTER INSERT OR UPDATE OR DELETE ON nivel_verificacao
  FOR EACH ROW EXECUTE FUNCTION auditar_parametrizacao();
CREATE TRIGGER tg_nivel_verificacao_sem_truncate BEFORE TRUNCATE ON nivel_verificacao
  FOR EACH STATEMENT EXECUTE FUNCTION bloquear_truncate();

-- Os requisitos de cada nível estão em nivel_requisito (carga na 0012).
INSERT INTO nivel_verificacao (nivel, nome) VALUES
  (1, 'Nível 1'),
  (2, 'Nível 2'),
  (3, 'Nível 3');

CREATE TABLE requisito_verificacao (
  codigo           text PRIMARY KEY CHECK (codigo ~ '^[a-z][a-z0-9_]*$'),
  nome             text NOT NULL,
  -- Perfis aos quais o requisito pode ser exigido.
  perfis           text[] NOT NULL
                   CHECK (cardinality(perfis) > 0 AND perfis <@ ARRAY['tomador','parceiro']),
  -- Tipo correspondente em verificacao_identidade, quando o requisito é cumprido por uma verificação.
  verificacao_tipo text CHECK (verificacao_tipo IN ('email','celular','cpf','documento_foto','selfie','cnh'))
);
CREATE TRIGGER tg_requisito_verificacao_auditoria AFTER INSERT OR UPDATE OR DELETE ON requisito_verificacao
  FOR EACH ROW EXECUTE FUNCTION auditar_parametrizacao();
CREATE TRIGGER tg_requisito_verificacao_sem_truncate BEFORE TRUNCATE ON requisito_verificacao
  FOR EACH STATEMENT EXECUTE FUNCTION bloquear_truncate();

INSERT INTO requisito_verificacao (codigo, nome, perfis, verificacao_tipo) VALUES
  ('email',                   'E-mail verificado',                       ARRAY['tomador','parceiro'], 'email'),
  ('celular',                 'Celular verificado',                      ARRAY['tomador','parceiro'], 'celular'),
  ('mfa',                     '2FA (TOTP) ativado',                      ARRAY['tomador','parceiro'], NULL),
  ('documento_foto',          'Documento com foto conferido com o CPF',  ARRAY['tomador','parceiro'], 'documento_foto'),
  ('selfie',                  'Selfie conferida com o documento',        ARRAY['tomador','parceiro'], 'selfie'),
  ('meio_pagamento_garantia', 'Meio de pagamento válido para a garantia', ARRAY['tomador'],           NULL),
  ('documentos_parceiro',     'Documentos exigidos pelo tipo aprovados', ARRAY['parceiro'],           NULL),
  ('conta_recebimento',       'Conta de recebimento aprovada',           ARRAY['parceiro'],           NULL);

-- ---------------------------------------------------------------------
-- Requisitos por nível e perfil (valores de negócio: carga na 0012)
-- Cada linha diz em que nível o requisito passa a ser exigido; o nível N exige
-- todos os requisitos dos níveis 1..N do mesmo perfil.
-- ---------------------------------------------------------------------

CREATE TABLE nivel_requisito (
  perfil           text NOT NULL CHECK (perfil IN ('tomador','parceiro')),
  requisito_codigo text NOT NULL REFERENCES requisito_verificacao(codigo),
  nivel            smallint NOT NULL REFERENCES nivel_verificacao(nivel),
  situacao         text NOT NULL DEFAULT 'a_definir' CHECK (situacao IN ('a_definir','definido')),
  observacao       text,
  criado_em        timestamptz NOT NULL DEFAULT now(),
  atualizado_em    timestamptz NOT NULL DEFAULT now(),
  -- Também atende "requisitos do perfil X".
  PRIMARY KEY (perfil, requisito_codigo)
);
CREATE TRIGGER tg_nivel_requisito_atualizado_em BEFORE UPDATE ON nivel_requisito
  FOR EACH ROW EXECUTE FUNCTION definir_atualizado_em();
CREATE TRIGGER tg_nivel_requisito_auditoria AFTER INSERT OR UPDATE OR DELETE ON nivel_requisito
  FOR EACH ROW EXECUTE FUNCTION auditar_parametrizacao();
CREATE TRIGGER tg_nivel_requisito_sem_truncate BEFORE TRUNCATE ON nivel_requisito
  FOR EACH STATEMENT EXECUTE FUNCTION bloquear_truncate();

CREATE FUNCTION nivel_requisito_perfil() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM requisito_verificacao
                  WHERE codigo = NEW.requisito_codigo AND NEW.perfil = ANY (perfis)) THEN
    RAISE EXCEPTION 'requisito "%" não se aplica ao perfil "%"', NEW.requisito_codigo, NEW.perfil
      USING ERRCODE = 'SC015';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER tg_nivel_requisito_perfil BEFORE INSERT OR UPDATE OF perfil, requisito_codigo ON nivel_requisito
  FOR EACH ROW EXECUTE FUNCTION nivel_requisito_perfil();

-- ---------------------------------------------------------------------
-- Nível mínimo por serviço e perfil (valores de negócio: carga na 0012)
-- ---------------------------------------------------------------------

CREATE TABLE servico_nivel_minimo (
  servico_codigo text NOT NULL REFERENCES servico_catalogo(codigo),
  perfil         text NOT NULL CHECK (perfil IN ('tomador','parceiro')),
  nivel_minimo   smallint REFERENCES nivel_verificacao(nivel),
  situacao       text NOT NULL DEFAULT 'a_definir' CHECK (situacao IN ('a_definir','definido')),
  observacao     text,
  criado_em      timestamptz NOT NULL DEFAULT now(),
  atualizado_em  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (servico_codigo, perfil),
  -- "a definir" não tem nível; "definido" sempre tem.
  CONSTRAINT ck_servico_nivel_situacao CHECK ((situacao = 'definido') = (nivel_minimo IS NOT NULL))
);
CREATE TRIGGER tg_servico_nivel_minimo_atualizado_em BEFORE UPDATE ON servico_nivel_minimo
  FOR EACH ROW EXECUTE FUNCTION definir_atualizado_em();
CREATE TRIGGER tg_servico_nivel_minimo_auditoria AFTER INSERT OR UPDATE OR DELETE ON servico_nivel_minimo
  FOR EACH ROW EXECUTE FUNCTION auditar_parametrizacao();
CREATE TRIGGER tg_servico_nivel_minimo_sem_truncate BEFORE TRUNCATE ON servico_nivel_minimo
  FOR EACH STATEMENT EXECUTE FUNCTION bloquear_truncate();

-- Nível mínimo exigido do perfil para o serviço. Recusa (SC013) se não houver valor definido:
-- "a definir" nunca vira um nível válido.
CREATE FUNCTION nivel_minimo_servico(p_servico text, p_perfil text) RETURNS smallint
LANGUAGE plpgsql STABLE AS $$
DECLARE v_nivel smallint; v_situacao text;
BEGIN
  IF p_perfil IS NULL OR p_perfil NOT IN ('tomador','parceiro') THEN
    RAISE EXCEPTION 'perfil inválido: %', p_perfil USING ERRCODE = '22023';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM servico_catalogo WHERE codigo = p_servico) THEN
    RAISE EXCEPTION 'serviço inexistente: %', p_servico USING ERRCODE = '22023';
  END IF;
  SELECT nivel_minimo, situacao INTO v_nivel, v_situacao
    FROM servico_nivel_minimo WHERE servico_codigo = p_servico AND perfil = p_perfil;
  IF v_situacao IS DISTINCT FROM 'definido' THEN
    RAISE EXCEPTION 'nível mínimo do serviço "%" para "%" está a definir', p_servico, p_perfil
      USING ERRCODE = 'SC013';
  END IF;
  RETURN v_nivel;
END $$;

-- O nível informado atende ao mínimo do serviço? (recusa com SC013 se o mínimo estiver a definir)
CREATE FUNCTION cumpre_nivel_minimo(p_perfil text, p_nivel integer, p_servico text) RETURNS boolean
LANGUAGE sql STABLE AS $$
  SELECT p_nivel >= nivel_minimo_servico(p_servico, p_perfil)
$$;

-- ---------------------------------------------------------------------
-- Nível atual (tomador e parceiro) e histórico
-- ---------------------------------------------------------------------

ALTER TABLE tomador
  ADD CONSTRAINT fk_tomador_nivel FOREIGN KEY (nivel_verificacao) REFERENCES nivel_verificacao(nivel);

ALTER TABLE parceiro
  ADD COLUMN nivel_verificacao smallint NOT NULL DEFAULT 1
    CONSTRAINT fk_parceiro_nivel REFERENCES nivel_verificacao(nivel);

CREATE TABLE nivel_verificacao_historico (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tomador_id     uuid REFERENCES tomador(usuario_id),
  parceiro_id    uuid REFERENCES parceiro(id),
  nivel          smallint NOT NULL REFERENCES nivel_verificacao(nivel),
  nivel_anterior smallint,          -- preenchido pelo trigger com o nível atual
  origem         text NOT NULL CHECK (origem IN ('automatica','central','carga_inicial')),
  concedido_por  uuid REFERENCES usuario(id),
  concedido_em   timestamptz NOT NULL DEFAULT clock_timestamp(),  -- hora do servidor (trigger)
  motivo         text,
  CONSTRAINT ck_historico_um_alvo CHECK (num_nonnulls(tomador_id, parceiro_id) = 1),
  -- Concessão manual da Central exige quem concedeu e justificativa.
  CONSTRAINT ck_historico_central CHECK (origem <> 'central' OR (concedido_por IS NOT NULL AND motivo IS NOT NULL))
);
-- Consulta prevista: "nível atual / histórico do tomador X" (e o mesmo para parceiro)
CREATE INDEX ix_nivel_historico_tomador  ON nivel_verificacao_historico (tomador_id, concedido_em DESC)
  WHERE tomador_id IS NOT NULL;
CREATE INDEX ix_nivel_historico_parceiro ON nivel_verificacao_historico (parceiro_id, concedido_em DESC)
  WHERE parceiro_id IS NOT NULL;

CREATE TRIGGER tg_nivel_historico_concedente_central
  BEFORE INSERT ON nivel_verificacao_historico
  FOR EACH ROW EXECUTE FUNCTION exige_perfil('central', 'concedido_por');

CREATE FUNCTION nivel_historico_preparar() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  NEW.concedido_em := clock_timestamp();
  IF NEW.tomador_id IS NOT NULL THEN
    SELECT nivel_verificacao INTO NEW.nivel_anterior FROM tomador WHERE usuario_id = NEW.tomador_id;
  ELSE
    SELECT nivel_verificacao INTO NEW.nivel_anterior FROM parceiro WHERE id = NEW.parceiro_id;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER tg_nivel_historico_preparar BEFORE INSERT ON nivel_verificacao_historico
  FOR EACH ROW EXECUTE FUNCTION nivel_historico_preparar();

CREATE FUNCTION nivel_historico_aplicar() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.tomador_id IS NOT NULL THEN
    UPDATE tomador SET nivel_verificacao = NEW.nivel WHERE usuario_id = NEW.tomador_id;
  ELSE
    UPDATE parceiro SET nivel_verificacao = NEW.nivel WHERE id = NEW.parceiro_id;
  END IF;
  RETURN NULL;
END $$;
CREATE TRIGGER tg_nivel_historico_aplicar AFTER INSERT ON nivel_verificacao_historico
  FOR EACH ROW EXECUTE FUNCTION nivel_historico_aplicar();

CREATE TRIGGER tg_nivel_historico_sem_alteracao BEFORE UPDATE OR DELETE ON nivel_verificacao_historico
  FOR EACH ROW EXECUTE FUNCTION somente_insercao();
CREATE TRIGGER tg_nivel_historico_sem_truncate BEFORE TRUNCATE ON nivel_verificacao_historico
  FOR EACH STATEMENT EXECUTE FUNCTION somente_insercao();
CREATE TRIGGER tg_nivel_historico_auditoria AFTER INSERT ON nivel_verificacao_historico
  FOR EACH ROW EXECUTE FUNCTION auditar_parametrizacao();

-- O nível atual só muda pelo histórico: começa no padrão (1) e cada alteração precisa
-- coincidir com o registro mais recente do histórico.
CREATE FUNCTION nivel_atual_pelo_historico() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_ultimo smallint;
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.nivel_verificacao <> 1 THEN
      RAISE EXCEPTION '%: o nível começa em 1; níveis acima são concedidos por nivel_verificacao_historico',
        TG_TABLE_NAME USING ERRCODE = 'SC011';
    END IF;
    RETURN NEW;
  END IF;

  IF TG_TABLE_NAME = 'tomador' THEN
    SELECT nivel INTO v_ultimo FROM nivel_verificacao_historico
     WHERE tomador_id = NEW.usuario_id ORDER BY concedido_em DESC LIMIT 1;
  ELSE
    SELECT nivel INTO v_ultimo FROM nivel_verificacao_historico
     WHERE parceiro_id = NEW.id ORDER BY concedido_em DESC LIMIT 1;
  END IF;
  IF v_ultimo IS DISTINCT FROM NEW.nivel_verificacao THEN
    RAISE EXCEPTION '%: nível % não corresponde ao histórico; registre a mudança em nivel_verificacao_historico',
      TG_TABLE_NAME, NEW.nivel_verificacao USING ERRCODE = 'SC011';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER tg_tomador_nivel_historico_ins BEFORE INSERT ON tomador
  FOR EACH ROW EXECUTE FUNCTION nivel_atual_pelo_historico();
CREATE TRIGGER tg_tomador_nivel_historico_upd BEFORE UPDATE OF nivel_verificacao ON tomador
  FOR EACH ROW WHEN (OLD.nivel_verificacao IS DISTINCT FROM NEW.nivel_verificacao)
  EXECUTE FUNCTION nivel_atual_pelo_historico();
CREATE TRIGGER tg_parceiro_nivel_historico_ins BEFORE INSERT ON parceiro
  FOR EACH ROW EXECUTE FUNCTION nivel_atual_pelo_historico();
CREATE TRIGGER tg_parceiro_nivel_historico_upd BEFORE UPDATE OF nivel_verificacao ON parceiro
  FOR EACH ROW WHEN (OLD.nivel_verificacao IS DISTINCT FROM NEW.nivel_verificacao)
  EXECUTE FUNCTION nivel_atual_pelo_historico();

-- ---------------------------------------------------------------------
-- Privilégios do safetycar_app
-- ---------------------------------------------------------------------

-- Parametrização: só leitura (alterações só por migração; ver 0012).
GRANT SELECT ON nivel_verificacao, requisito_verificacao, nivel_requisito, servico_nivel_minimo
  TO safetycar_app;
-- Histórico: o app registra a mudança de nível (cálculo automático ou ação da Central).
GRANT SELECT, INSERT ON nivel_verificacao_historico TO safetycar_app;
GRANT EXECUTE ON FUNCTION
  nivel_minimo_servico(text, text),
  cumpre_nivel_minimo(text, integer, text)
TO safetycar_app;
