-- 0011 — Política de garantia e catálogo de provedores de pagamento.
--
-- - Garantia: pré-autorização no cartão ou Pix pré-pago; valor fixo (centavos) ou percentual
--   (pontos-base) da estimativa do serviço; por serviço e nível de verificação do tomador; com
--   vigência sem sobreposição e imutável (mesma regra da 0010: SC012).
-- - Provedor de pagamento: só o catálogo e as capacidades. NENHUM segredo, chave, token,
--   credencial ou URL de callback no banco: isso fica na configuração do backend (fora do Git).
-- - Fora desta fase: pagamento efetivo, pré-autorização real, repasse e integração com o provedor.

-- ---------------------------------------------------------------------
-- Política de garantia
-- ---------------------------------------------------------------------

CREATE TABLE politica_garantia (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  servico_codigo    text NOT NULL REFERENCES servico_catalogo(codigo),
  nivel_verificacao smallint NOT NULL REFERENCES nivel_verificacao(nivel),  -- nível do tomador
  modalidade        text NOT NULL CHECK (modalidade IN ('pre_autorizacao_cartao','pix_pre_pago')),
  calculo           text NOT NULL CHECK (calculo IN ('valor_fixo','percentual')),
  valor_centavos    bigint  CHECK (valor_centavos >= 0),
  percentual_bp     integer CHECK (percentual_bp BETWEEN 0 AND 10000),       -- da estimativa do serviço
  situacao          text NOT NULL DEFAULT 'a_definir' CHECK (situacao IN ('a_definir','definido')),
  observacao        text,
  inicio_vigencia   timestamptz NOT NULL DEFAULT now(),
  fim_vigencia      timestamptz,
  criado_em         timestamptz NOT NULL DEFAULT now(),
  atualizado_em     timestamptz NOT NULL DEFAULT now(),

  -- Exatamente um valor, conforme o cálculo.
  CONSTRAINT ck_garantia_calculo CHECK (
       (calculo = 'valor_fixo' AND valor_centavos IS NOT NULL AND percentual_bp IS NULL)
    OR (calculo = 'percentual' AND percentual_bp  IS NOT NULL AND valor_centavos IS NULL)),
  -- "a definir" fica zerado e marcado.
  CONSTRAINT ck_garantia_a_definir CHECK (
    situacao = 'definido' OR coalesce(valor_centavos, 0) + coalesce(percentual_bp, 0) = 0),
  CONSTRAINT ck_garantia_vigencia CHECK (fim_vigencia IS NULL OR fim_vigencia >= inicio_vigencia),
  CONSTRAINT ex_garantia_vigencia EXCLUDE USING gist (
    servico_codigo WITH =,
    nivel_verificacao WITH =,
    modalidade WITH =,
    tstzrange(inicio_vigencia, fim_vigencia, '[)') WITH &&)
);
CREATE TRIGGER tg_politica_garantia_imutavel BEFORE INSERT OR UPDATE OR DELETE ON politica_garantia
  FOR EACH ROW EXECUTE FUNCTION vigencia_imutavel();
CREATE TRIGGER tg_politica_garantia_atualizado_em BEFORE UPDATE ON politica_garantia
  FOR EACH ROW EXECUTE FUNCTION definir_atualizado_em();
CREATE TRIGGER tg_politica_garantia_auditoria AFTER INSERT OR UPDATE OR DELETE ON politica_garantia
  FOR EACH ROW EXECUTE FUNCTION auditar_parametrizacao();
CREATE TRIGGER tg_politica_garantia_sem_truncate BEFORE TRUNCATE ON politica_garantia
  FOR EACH STATEMENT EXECUTE FUNCTION bloquear_truncate();

-- Política vigente para o serviço, nível do tomador e modalidade. Recusa (SC013) se não houver
-- política ou se estiver "a definir": nunca devolve garantia zero por falta de decisão.
CREATE FUNCTION politica_garantia_vigente(p_servico text, p_nivel integer, p_modalidade text,
                                          p_instante timestamptz DEFAULT now())
RETURNS politica_garantia
LANGUAGE plpgsql STABLE AS $$
DECLARE v_politica politica_garantia;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM servico_catalogo WHERE codigo = p_servico) THEN
    RAISE EXCEPTION 'serviço inexistente: %', p_servico USING ERRCODE = '22023';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM nivel_verificacao WHERE nivel = p_nivel) THEN
    RAISE EXCEPTION 'nível inexistente: %', p_nivel USING ERRCODE = '22023';
  END IF;
  IF p_modalidade IS NULL OR p_modalidade NOT IN ('pre_autorizacao_cartao','pix_pre_pago') THEN
    RAISE EXCEPTION 'modalidade inválida: %', p_modalidade USING ERRCODE = '22023';
  END IF;
  IF p_instante IS NULL THEN
    RAISE EXCEPTION 'instante é obrigatório' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO v_politica
    FROM politica_garantia
   WHERE servico_codigo = p_servico
     AND nivel_verificacao = p_nivel
     AND modalidade = p_modalidade
     AND tstzrange(inicio_vigencia, fim_vigencia, '[)') @> p_instante;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'sem política de garantia vigente para %/nível %/% em %',
      p_servico, p_nivel, p_modalidade, p_instante USING ERRCODE = 'SC013';
  END IF;
  IF v_politica.situacao <> 'definido' THEN
    RAISE EXCEPTION 'política de garantia %/nível %/% está a definir',
      p_servico, p_nivel, p_modalidade USING ERRCODE = 'SC013';
  END IF;
  RETURN v_politica;
END $$;

-- ---------------------------------------------------------------------
-- Provedores de pagamento (catálogo e capacidades; sem credenciais)
-- ---------------------------------------------------------------------

CREATE TABLE provedor_pagamento (
  id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  codigo                  text NOT NULL CHECK (codigo ~ '^[a-z][a-z0-9_]*$'),
  nome                    text NOT NULL,
  ambiente                text NOT NULL CHECK (ambiente IN ('sandbox','producao')),
  suporta_pre_autorizacao boolean NOT NULL DEFAULT false,
  suporta_pix             boolean NOT NULL DEFAULT false,
  suporta_split           boolean NOT NULL DEFAULT false,
  ativo                   boolean NOT NULL DEFAULT false,   -- ativação é explícita
  observacao              text,
  criado_em               timestamptz NOT NULL DEFAULT now(),
  atualizado_em           timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_provedor_codigo_ambiente UNIQUE (codigo, ambiente)
);
CREATE TRIGGER tg_provedor_pagamento_atualizado_em BEFORE UPDATE ON provedor_pagamento
  FOR EACH ROW EXECUTE FUNCTION definir_atualizado_em();
CREATE TRIGGER tg_provedor_pagamento_auditoria AFTER INSERT OR UPDATE OR DELETE ON provedor_pagamento
  FOR EACH ROW EXECUTE FUNCTION auditar_parametrizacao();
CREATE TRIGGER tg_provedor_pagamento_sem_truncate BEFORE TRUNCATE ON provedor_pagamento
  FOR EACH STATEMENT EXECUTE FUNCTION bloquear_truncate();

-- ---------------------------------------------------------------------
-- Privilégios do safetycar_app: só leitura (alterações só por migração; ver 0012)
-- ---------------------------------------------------------------------

GRANT SELECT ON politica_garantia, provedor_pagamento TO safetycar_app;
GRANT EXECUTE ON FUNCTION politica_garantia_vigente(text, integer, text, timestamptz) TO safetycar_app;
