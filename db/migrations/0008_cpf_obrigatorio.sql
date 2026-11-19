-- 0008 — CPF obrigatório.
--
-- Tomador: o CPF passa a ser exigido NO CADASTRO (decidido): cpf_cifrado e cpf_hash NOT NULL.
--   A unicidade (UNIQUE em cpf_hash) e o CHECK de par (ck_tomador_cpf_par) da 0003 continuam.
--
-- Parceiro PJ e MEI: CPF do responsável legal, cifrado pela aplicação e com hash (mesma chave de
--   HMAC e mesma normalização: só os 11 dígitos), exigido NA APROVAÇÃO do credenciamento.
--   Sem UNIQUE: a mesma pessoa pode responder por mais de uma empresa ou ser também tomador.
--   Parceiro PF não tem responsável separado: o próprio cpf_hash (obrigatório desde a 0004) é dele.
--
-- Novo código de erro:
--   SC014 aprovação (ou parceiro já aprovado) de PJ/MEI sem CPF do responsável

-- ---------------------------------------------------------------------
-- Tomador
-- ---------------------------------------------------------------------

-- Falha cedo e com mensagem clara se já houver tomador sem CPF (nada é apagado nem inventado).
DO $$
DECLARE v_sem_cpf bigint;
BEGIN
  SELECT count(*) INTO v_sem_cpf FROM tomador WHERE cpf_hash IS NULL OR cpf_cifrado IS NULL;
  IF v_sem_cpf > 0 THEN
    RAISE EXCEPTION '0008: há % tomador(es) sem CPF; complete o CPF antes de aplicar esta migração', v_sem_cpf;
  END IF;
END $$;

ALTER TABLE tomador
  ALTER COLUMN cpf_cifrado SET NOT NULL,
  ALTER COLUMN cpf_hash    SET NOT NULL;

-- ---------------------------------------------------------------------
-- Parceiro: responsável legal (PJ e MEI)
-- ---------------------------------------------------------------------

ALTER TABLE parceiro
  ADD COLUMN responsavel_nome        text,
  ADD COLUMN responsavel_cpf_cifrado bytea,
  ADD COLUMN responsavel_cpf_hash    dom_hmac,
  ADD CONSTRAINT ck_parceiro_responsavel_cpf_par
    CHECK ((responsavel_cpf_cifrado IS NULL) = (responsavel_cpf_hash IS NULL)),
  ADD CONSTRAINT ck_parceiro_responsavel_nome
    CHECK (responsavel_cpf_hash IS NULL OR responsavel_nome IS NOT NULL),
  -- PF: o titular é o próprio parceiro (cpf_hash); não há responsável separado.
  ADD CONSTRAINT ck_parceiro_responsavel_so_pj_mei
    CHECK (tipo_pessoa IN ('pj','mei') OR responsavel_cpf_hash IS NULL);

-- Consulta prevista: "este CPF (bloqueado, ou de um tomador) responde por quais parceiros?" (antifraude)
CREATE INDEX ix_parceiro_responsavel_cpf ON parceiro (responsavel_cpf_hash)
  WHERE responsavel_cpf_hash IS NOT NULL;

-- Redefine a regra de aprovação da 0004 acrescentando o responsável (SC014).
CREATE OR REPLACE FUNCTION parceiro_aprovacao() RETURNS trigger
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

  IF NEW.tipo_pessoa IN ('pj','mei') AND NEW.responsavel_cpf_hash IS NULL THEN
    RAISE EXCEPTION 'parceiro % (%) não pode ser aprovado sem o CPF do responsável', NEW.id, NEW.tipo_pessoa
      USING ERRCODE = 'SC014';
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

-- Parceiro PJ/MEI já aprovado não pode ficar sem o CPF do responsável (pode trocá-lo, não removê-lo).
CREATE FUNCTION parceiro_responsavel_mantido() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.status_credenciamento = 'aprovado' AND NEW.tipo_pessoa IN ('pj','mei')
     AND NEW.responsavel_cpf_hash IS NULL AND OLD.responsavel_cpf_hash IS NOT NULL THEN
    RAISE EXCEPTION 'parceiro % está aprovado; o CPF do responsável não pode ser removido', NEW.id
      USING ERRCODE = 'SC014';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER tg_parceiro_responsavel_mantido BEFORE UPDATE OF responsavel_cpf_hash ON parceiro
  FOR EACH ROW EXECUTE FUNCTION parceiro_responsavel_mantido();

-- GRANTs: nenhum objeto novo acessível ao app (as colunas novas herdam o privilégio de tabela de
-- parceiro concedido na 0007; parceiro_aprovacao e parceiro_responsavel_mantido são funções de trigger).
