-- 0013 — Nível 0, "cadastro incompleto".
--
-- Por quê: desde a 0003 tomador e parceiro nasciam no nível 1, mas o nível 1 significa e-mail e
-- celular verificados. Quem acabou de criar a conta aparecia como nível 1 e poderia ser liberado
-- para serviços quando as regras entrarem em uso. Agora todo cadastro nasce no nível 0 e só sobe
-- por uma linha no histórico (regra da 0009, inalterada). Supera o comentário da 0003
-- ("1 = e-mail + 2FA; 2 = celular e CPF; 3 = documento com foto").
--
-- Decidido:
--   - nível 0 não tem requisitos, não é nível mínimo de serviço e não tem política de garantia
--     (CHECK >= 1 nessas tabelas); mínimo 0 só por migração nova e decisão explícita;
--   - cumpre_nivel_minimo continua recusando com SC013 quando o mínimo está "a definir",
--     mesmo para o nível 0 (a função nunca responde com parâmetro não decidido);
--   - garantia consultada para o nível 0: 22023 (não se aplica); SC013 só para "a definir";
--   - registros no nível 1 sem nenhum histórico (chegaram lá só pelo padrão antigo) são
--     rebaixados ao 0 por uma NOVA linha de histórico com origem 'migracao'; o histórico
--     existente não é alterado.

-- ---------------------------------------------------------------------
-- Catálogo
-- ---------------------------------------------------------------------

ALTER TABLE nivel_verificacao DROP CONSTRAINT nivel_verificacao_nivel_check;
ALTER TABLE nivel_verificacao ADD CONSTRAINT nivel_verificacao_nivel_check CHECK (nivel BETWEEN 0 AND 3);

-- Auditado pelo trigger da 0009.
INSERT INTO nivel_verificacao (nivel, nome, descricao) VALUES
  (0, 'Cadastro incompleto', 'Conta criada, sem verificação registrada. Não cumpre o nível mínimo de nenhum serviço.');

-- ---------------------------------------------------------------------
-- Onde o nível 0 cabe: nível atual (tomador, parceiro) e histórico
-- ---------------------------------------------------------------------

-- O CHECK de 1 a 3 da 0003 sai; a FK para nivel_verificacao (0009) já limita os valores.
ALTER TABLE tomador DROP CONSTRAINT tomador_nivel_verificacao_check;
ALTER TABLE tomador  ALTER COLUMN nivel_verificacao SET DEFAULT 0;
ALTER TABLE parceiro ALTER COLUMN nivel_verificacao SET DEFAULT 0;

ALTER TABLE nivel_verificacao_historico DROP CONSTRAINT nivel_verificacao_historico_origem_check;
ALTER TABLE nivel_verificacao_historico ADD CONSTRAINT nivel_verificacao_historico_origem_check
  CHECK (origem IN ('automatica','central','carga_inicial','migracao'));

-- ---------------------------------------------------------------------
-- Onde o nível 0 não cabe
-- ---------------------------------------------------------------------

ALTER TABLE nivel_requisito
  ADD CONSTRAINT ck_nivel_requisito_sem_zero CHECK (nivel >= 1);
ALTER TABLE servico_nivel_minimo
  ADD CONSTRAINT ck_servico_nivel_minimo_sem_zero CHECK (nivel_minimo >= 1);
ALTER TABLE politica_garantia
  ADD CONSTRAINT ck_garantia_nivel_sem_zero CHECK (nivel_verificacao >= 1);

-- ---------------------------------------------------------------------
-- Funções
-- ---------------------------------------------------------------------

-- Igual à 0009, exceto o nível de criação: 0 em vez de 1.
CREATE OR REPLACE FUNCTION nivel_atual_pelo_historico() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_ultimo smallint;
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.nivel_verificacao <> 0 THEN
      RAISE EXCEPTION '%: o cadastro começa no nível 0; níveis acima são concedidos por nivel_verificacao_historico',
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

-- Valida o nível informado (22023) e depois o mínimo do serviço (SC013 se "a definir", também
-- para o nível 0). Como todo mínimo definido é >= 1, o nível 0 nunca cumpre.
CREATE OR REPLACE FUNCTION cumpre_nivel_minimo(p_perfil text, p_nivel integer, p_servico text) RETURNS boolean
LANGUAGE plpgsql STABLE AS $$
BEGIN
  IF p_nivel IS NULL OR NOT EXISTS (SELECT 1 FROM nivel_verificacao WHERE nivel = p_nivel) THEN
    RAISE EXCEPTION 'nível inválido: %', p_nivel USING ERRCODE = '22023';
  END IF;
  RETURN p_nivel >= nivel_minimo_servico(p_servico, p_perfil);
END $$;

-- Igual à 0011, mais a recusa do nível 0 (não se aplica: 22023).
CREATE OR REPLACE FUNCTION politica_garantia_vigente(p_servico text, p_nivel integer, p_modalidade text,
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
  IF p_nivel = 0 THEN
    RAISE EXCEPTION 'nível 0 (cadastro incompleto) não tem política de garantia' USING ERRCODE = '22023';
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
-- Registros existentes
-- ---------------------------------------------------------------------

-- Acima de 1 sem histórico é impossível desde a 0009; se aparecer, parar e investigar.
DO $$
DECLARE v_qtd bigint;
BEGIN
  SELECT (SELECT count(*) FROM tomador t WHERE t.nivel_verificacao > 1
            AND NOT EXISTS (SELECT 1 FROM nivel_verificacao_historico h WHERE h.tomador_id = t.usuario_id))
       + (SELECT count(*) FROM parceiro p WHERE p.nivel_verificacao > 1
            AND NOT EXISTS (SELECT 1 FROM nivel_verificacao_historico h WHERE h.parceiro_id = p.id))
    INTO v_qtd;
  IF v_qtd > 0 THEN
    RAISE EXCEPTION '0013: % registro(s) acima do nível 1 sem histórico; investigar antes de aplicar', v_qtd;
  END IF;
END $$;

-- Nível 1 sem histórico = só o padrão antigo: nova linha de histórico para o nível 0.
-- (O trigger da 0009 registra nivel_anterior = 1 e atualiza o nível atual.)
INSERT INTO nivel_verificacao_historico (tomador_id, nivel, origem, motivo)
SELECT t.usuario_id, 0, 'migracao', '0013: nível 1 era só o padrão; nenhuma verificação registrada'
  FROM tomador t
 WHERE t.nivel_verificacao = 1
   AND NOT EXISTS (SELECT 1 FROM nivel_verificacao_historico h WHERE h.tomador_id = t.usuario_id);

INSERT INTO nivel_verificacao_historico (parceiro_id, nivel, origem, motivo)
SELECT p.id, 0, 'migracao', '0013: nível 1 era só o padrão; nenhuma verificação registrada'
  FROM parceiro p
 WHERE p.nivel_verificacao = 1
   AND NOT EXISTS (SELECT 1 FROM nivel_verificacao_historico h WHERE h.parceiro_id = p.id);

-- GRANTs: nenhum objeto novo. CREATE OR REPLACE mantém o EXECUTE do safetycar_app concedido
-- nas 0009 e 0011; o catálogo continua só leitura para o app (0009 e 0012).
