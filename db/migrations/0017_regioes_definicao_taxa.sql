-- 0017 — Regiões (atalho de escopo) e definição da primeira tarifa, em lote.
--
-- Por quê: as 42 regras de taxa da carga (0012) estão "a definir", e o reajuste (0015) só atua
-- sobre regra definida. O desenho de 23/11/2026 deixou em aberto quem cadastra a primeira tarifa;
-- decidido: um LOTE de definições, solicitado por quem tem solicitar_reajuste_taxa e aprovado
-- (numa só decisão) por OUTRO operador com aprovar_reajuste_taxa. Mesmo controle do reajuste,
-- sem migração por valor.
--
-- Regiões (decidido): regra_taxa continua por UF ou nacional. A região é só um ATALHO de escopo:
-- um item com "regiao" vira um item por UF daquela região. Regiões e UFs: carga IBGE, só por
-- migração.
--
-- O que cada item faz na aprovação (no instante da aprovação, depois dos locks):
--   - escopo com regra vigente "a definir": encerra-a nesse instante e abre a definida, contígua
--     (regra_origem_id = a regra a definir);
--   - escopo sem regra vigente: cria a regra (ex.: a de uma UF, que passa a prevalecer sobre a
--     nacional naquela UF);
--   - escopo com regra vigente JÁ DEFINIDA: recusa (SC028; o caminho é o reajuste);
--   - escopo com regra futura agendada: recusa (SC021).
-- Início sempre imediato, nunca no passado. Sem aprovação parcial: tudo ou nada.
--
-- Itens: jsonb, uma lista de objetos com as chaves
--   tipo_parceiro, servico, componente, valor (inteiro na unidade: centavos, centavos por km ou
--   pontos-base), unidade (opcional, exceto no cancelamento, que é em centavos ou pontos-base) e
--   EXATAMENTE UM de: uf, regiao ou nacional (= true). Chave desconhecida é recusada.
--   - A combinação tipo × serviço precisa já existir em regra_taxa (a carga é o catálogo de
--     combinações; combinação nova só por migração).
--   - valor 0 é aceito como valor definido (ex.: sem taxa de não comparecimento): "a definir"
--     continua sendo outra coisa, e nunca vale como zero.
--   - por_km usa base_distancia linha_reta (distância rodoviária não está decidida).
--
-- Concorrência: solicitação e aprovação tomam pg_advisory_xact_lock(150001), o mesmo do
-- reajuste: toda alteração de regra_taxa pela Central fica em série. A aprovação ainda trava o
-- lote e as regras a encerrar (FOR UPDATE) e só então lê o relógio (clock_timestamp()).
--
-- Códigos de erro novos:
--   SC024 já existe pedido em aberto para o mesmo alvo (aqui: item de um lote de definição
--         ainda sem decisão, no mesmo escopo)
--   SC028 definição de regra que já está definida (o caminho é o reajuste)

-- ---------------------------------------------------------------------
-- Regiões (parametrização: só por migração)
-- ---------------------------------------------------------------------

CREATE TABLE regiao (
  codigo        text PRIMARY KEY CHECK (codigo ~ '^[a-z][a-z0-9_]*$'),
  nome          text NOT NULL,
  criado_em     timestamptz NOT NULL DEFAULT now(),
  atualizado_em timestamptz NOT NULL DEFAULT now()
);
CREATE TRIGGER tg_regiao_atualizado_em BEFORE UPDATE ON regiao
  FOR EACH ROW EXECUTE FUNCTION definir_atualizado_em();
CREATE TRIGGER tg_regiao_auditoria AFTER INSERT OR UPDATE OR DELETE ON regiao
  FOR EACH ROW EXECUTE FUNCTION auditar_parametrizacao();
CREATE TRIGGER tg_regiao_sem_truncate BEFORE TRUNCATE ON regiao
  FOR EACH STATEMENT EXECUTE FUNCTION bloquear_truncate();

CREATE TABLE regiao_uf (
  uf            dom_uf PRIMARY KEY,
  regiao_codigo text NOT NULL REFERENCES regiao(codigo),
  criado_em     timestamptz NOT NULL DEFAULT now(),
  -- Alvo da FK composta de definicao_taxa_item (a UF do item pertence à região informada).
  CONSTRAINT uq_regiao_uf_regiao UNIQUE (uf, regiao_codigo)
);
-- Consulta prevista: "UFs da região X" (expansão do atalho)
CREATE INDEX ix_regiao_uf_regiao ON regiao_uf (regiao_codigo);
CREATE TRIGGER tg_regiao_uf_auditoria AFTER INSERT OR UPDATE OR DELETE ON regiao_uf
  FOR EACH ROW EXECUTE FUNCTION auditar_parametrizacao();
CREATE TRIGGER tg_regiao_uf_sem_truncate BEFORE TRUNCATE ON regiao_uf
  FOR EACH STATEMENT EXECUTE FUNCTION bloquear_truncate();

INSERT INTO regiao (codigo, nome) VALUES
  ('norte',        'Norte'),
  ('nordeste',     'Nordeste'),
  ('centro_oeste', 'Centro-Oeste'),
  ('sudeste',      'Sudeste'),
  ('sul',          'Sul');

INSERT INTO regiao_uf (uf, regiao_codigo) VALUES
  ('AC','norte'), ('AP','norte'), ('AM','norte'), ('PA','norte'), ('RO','norte'), ('RR','norte'), ('TO','norte'),
  ('AL','nordeste'), ('BA','nordeste'), ('CE','nordeste'), ('MA','nordeste'), ('PB','nordeste'),
  ('PE','nordeste'), ('PI','nordeste'), ('RN','nordeste'), ('SE','nordeste'),
  ('DF','centro_oeste'), ('GO','centro_oeste'), ('MT','centro_oeste'), ('MS','centro_oeste'),
  ('ES','sudeste'), ('MG','sudeste'), ('RJ','sudeste'), ('SP','sudeste'),
  ('PR','sul'), ('RS','sul'), ('SC','sul');

DO $$
BEGIN
  IF (SELECT count(*) FROM regiao_uf) <> 27
     OR EXISTS (SELECT 1 FROM regiao_uf WHERE uf_codigo_ibge(uf) IS NULL) THEN
    RAISE EXCEPTION '0017: regiao_uf deve cobrir as 27 UFs, uma vez cada';
  END IF;
END $$;

-- UFs de uma região (22023 se a região não existir).
CREATE FUNCTION ufs_da_regiao(p_regiao text) RETURNS text[]
LANGUAGE plpgsql STABLE AS $$
DECLARE v text[];
BEGIN
  SELECT array_agg(uf::text ORDER BY uf) INTO v FROM regiao_uf WHERE regiao_codigo = p_regiao;
  IF v IS NULL THEN
    RAISE EXCEPTION 'região inexistente: %', p_regiao USING ERRCODE = '22023';
  END IF;
  RETURN v;
END $$;

-- ---------------------------------------------------------------------
-- Lote de definição (somente inserção), itens (somente inserção) e decisão (uma por lote)
-- ---------------------------------------------------------------------

CREATE TABLE definicao_taxa (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  motivo         text NOT NULL CHECK (btrim(motivo) <> ''),
  solicitado_por uuid NOT NULL REFERENCES operador_central(usuario_id),
  solicitado_em  timestamptz NOT NULL DEFAULT clock_timestamp(),
  papel_bd       text NOT NULL DEFAULT session_user
);
-- Consulta prevista: "lotes de um operador" (acompanhamento na Central)
CREATE INDEX ix_definicao_solicitado_por ON definicao_taxa (solicitado_por, solicitado_em DESC);

CREATE FUNCTION definicao_taxa_preparar() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  NEW.solicitado_em := clock_timestamp();
  NEW.papel_bd := session_user;
  RETURN NEW;
END $$;
CREATE TRIGGER tg_definicao_taxa_preparar BEFORE INSERT ON definicao_taxa
  FOR EACH ROW EXECUTE FUNCTION definicao_taxa_preparar();
CREATE TRIGGER tg_definicao_taxa_sem_alteracao BEFORE UPDATE OR DELETE ON definicao_taxa
  FOR EACH ROW EXECUTE FUNCTION somente_insercao();
CREATE TRIGGER tg_definicao_taxa_sem_truncate BEFORE TRUNCATE ON definicao_taxa
  FOR EACH STATEMENT EXECUTE FUNCTION somente_insercao();
CREATE TRIGGER tg_definicao_taxa_auditoria AFTER INSERT ON definicao_taxa
  FOR EACH ROW EXECUTE FUNCTION auditar_parametrizacao();

CREATE TABLE definicao_taxa_item (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  definicao_id         uuid NOT NULL REFERENCES definicao_taxa(id),
  tipo_parceiro_codigo text NOT NULL REFERENCES tipo_parceiro(codigo),
  servico_codigo       text NOT NULL REFERENCES servico_catalogo(codigo),
  uf                   dom_uf,          -- nulo = nacional
  regiao_codigo        text,            -- de qual região o item veio (atalho), se veio
  componente           text NOT NULL
                       CHECK (componente IN ('base','por_km','minimo','cancelamento',
                                             'nao_comparecimento','comissao_plataforma')),
  unidade              text NOT NULL CHECK (unidade IN ('centavos','centavos_por_km','pontos_base')),
  valor                bigint NOT NULL CHECK (valor >= 0),
  CONSTRAINT fk_item_regiao_uf FOREIGN KEY (uf, regiao_codigo) REFERENCES regiao_uf (uf, regiao_codigo),
  CONSTRAINT ck_item_regiao_com_uf CHECK (regiao_codigo IS NULL OR uf IS NOT NULL),
  CONSTRAINT ck_item_unidade CHECK (
       (componente IN ('base','minimo','nao_comparecimento') AND unidade = 'centavos')
    OR (componente = 'por_km'              AND unidade = 'centavos_por_km')
    OR (componente = 'cancelamento'        AND unidade IN ('centavos','pontos_base'))
    OR (componente = 'comissao_plataforma' AND unidade = 'pontos_base')),
  CONSTRAINT ck_item_pontos_base CHECK (unidade <> 'pontos_base' OR valor <= 10000),
  CONSTRAINT uq_item_escopo UNIQUE NULLS NOT DISTINCT (definicao_id, tipo_parceiro_codigo, servico_codigo, uf, componente)
);
CREATE TRIGGER tg_definicao_item_sem_alteracao BEFORE UPDATE OR DELETE ON definicao_taxa_item
  FOR EACH ROW EXECUTE FUNCTION somente_insercao();
CREATE TRIGGER tg_definicao_item_sem_truncate BEFORE TRUNCATE ON definicao_taxa_item
  FOR EACH STATEMENT EXECUTE FUNCTION somente_insercao();
CREATE TRIGGER tg_definicao_item_auditoria AFTER INSERT ON definicao_taxa_item
  FOR EACH ROW EXECUTE FUNCTION auditar_parametrizacao();

CREATE TABLE definicao_taxa_decisao (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  definicao_id    uuid NOT NULL UNIQUE REFERENCES definicao_taxa(id),
  situacao        text NOT NULL CHECK (situacao IN ('aprovado','rejeitado','cancelado')),
  decidido_por    uuid NOT NULL REFERENCES operador_central(usuario_id),
  decidido_em     timestamptz NOT NULL DEFAULT clock_timestamp(),
  motivo          text NOT NULL CHECK (btrim(motivo) <> ''),
  inicio_efetivo  timestamptz,
  regras_afetadas integer CHECK (regras_afetadas > 0),
  papel_bd        text NOT NULL DEFAULT session_user,
  CONSTRAINT ck_definicao_decisao_aprovacao CHECK (
    (situacao = 'aprovado') = (inicio_efetivo IS NOT NULL)
    AND (situacao = 'aprovado') = (regras_afetadas IS NOT NULL))
);
-- decidido_em e papel_bd pela hora e pelo papel do servidor (mesma função da 0015).
CREATE TRIGGER tg_definicao_decisao_preparar BEFORE INSERT ON definicao_taxa_decisao
  FOR EACH ROW EXECUTE FUNCTION reajuste_decisao_preparar();
CREATE TRIGGER tg_definicao_decisao_sem_alteracao BEFORE UPDATE OR DELETE ON definicao_taxa_decisao
  FOR EACH ROW EXECUTE FUNCTION somente_insercao();
CREATE TRIGGER tg_definicao_decisao_sem_truncate BEFORE TRUNCATE ON definicao_taxa_decisao
  FOR EACH STATEMENT EXECUTE FUNCTION somente_insercao();
CREATE TRIGGER tg_definicao_decisao_auditoria AFTER INSERT ON definicao_taxa_decisao
  FOR EACH ROW EXECUTE FUNCTION auditar_parametrizacao();

-- Situação derivada: "solicitado" enquanto não há decisão.
CREATE VIEW vw_definicao_taxa WITH (security_invoker = true) AS
SELECT d.*,
       (SELECT count(*) FROM definicao_taxa_item i WHERE i.definicao_id = d.id) AS itens,
       coalesce(x.situacao, 'solicitado') AS situacao,
       x.decidido_por, x.decidido_em, x.motivo AS motivo_decisao, x.inicio_efetivo, x.regras_afetadas
  FROM definicao_taxa d
  LEFT JOIN definicao_taxa_decisao x ON x.definicao_id = d.id;

-- ---------------------------------------------------------------------
-- regra_taxa: ligação com o lote de definição
-- ---------------------------------------------------------------------

-- A 0015 exigia regra_origem_id se e só se reajuste_id. Agora a definição também aponta a regra
-- "a definir" que substituiu (e a regra criada do zero não tem origem).
ALTER TABLE regra_taxa
  ADD COLUMN definicao_id uuid REFERENCES definicao_taxa(id),
  DROP CONSTRAINT ck_regra_taxa_reajuste,
  ADD CONSTRAINT ck_regra_taxa_reajuste CHECK (reajuste_id IS NULL OR regra_origem_id IS NOT NULL),
  ADD CONSTRAINT ck_regra_taxa_origem CHECK (regra_origem_id IS NULL OR reajuste_id IS NOT NULL OR definicao_id IS NOT NULL),
  ADD CONSTRAINT ck_regra_taxa_um_lote CHECK (reajuste_id IS NULL OR definicao_id IS NULL);
-- Consulta prevista: "regras criadas pelo lote de definição X"
CREATE INDEX ix_regra_taxa_definicao ON regra_taxa (definicao_id) WHERE definicao_id IS NOT NULL;

-- ---------------------------------------------------------------------
-- Itens: validação e expansão das regiões (só leitura)
-- ---------------------------------------------------------------------

CREATE FUNCTION definicao_itens(p_itens jsonb)
RETURNS TABLE (tipo_parceiro_codigo text, servico_codigo text, uf text, regiao_codigo text,
               componente text, unidade text, valor bigint)
LANGUAGE plpgsql STABLE AS $$
DECLARE
  e jsonb; n int := 0; v_extra text; v_alvos int;
  v_tipo text; v_servico text; v_comp text; v_unid text; v_valor numeric; v_uf text; u text;
BEGIN
  IF p_itens IS NULL OR jsonb_typeof(p_itens) <> 'array' OR jsonb_array_length(p_itens) = 0 THEN
    RAISE EXCEPTION 'itens: informe uma lista não vazia' USING ERRCODE = '22023';
  END IF;
  FOR e IN SELECT x FROM jsonb_array_elements(p_itens) x LOOP
    n := n + 1;
    IF jsonb_typeof(e) <> 'object' THEN
      RAISE EXCEPTION 'item %: precisa ser um objeto', n USING ERRCODE = '22023';
    END IF;
    SELECT string_agg(k, ', ') INTO v_extra FROM jsonb_object_keys(e) k
     WHERE k NOT IN ('tipo_parceiro','servico','uf','regiao','nacional','componente','unidade','valor');
    IF v_extra IS NOT NULL THEN
      RAISE EXCEPTION 'item %: chave desconhecida: %', n, v_extra USING ERRCODE = '22023';
    END IF;

    v_tipo := e ->> 'tipo_parceiro';
    IF v_tipo IS NULL OR NOT EXISTS (SELECT 1 FROM tipo_parceiro WHERE codigo = v_tipo) THEN
      RAISE EXCEPTION 'item %: tipo de parceiro inválido: %', n, v_tipo USING ERRCODE = '22023';
    END IF;
    v_servico := e ->> 'servico';
    IF v_servico IS NULL OR NOT EXISTS (SELECT 1 FROM servico_catalogo WHERE codigo = v_servico) THEN
      RAISE EXCEPTION 'item %: serviço inválido: %', n, v_servico USING ERRCODE = '22023';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM regra_taxa r WHERE r.tipo_parceiro_codigo = v_tipo AND r.servico_codigo = v_servico) THEN
      RAISE EXCEPTION 'item %: a combinação %/% não tem regra na carga; combinação nova só por migração', n, v_tipo, v_servico
        USING ERRCODE = '22023';
    END IF;

    v_comp := e ->> 'componente';
    IF v_comp IS NULL OR v_comp NOT IN ('base','por_km','minimo','cancelamento','nao_comparecimento','comissao_plataforma') THEN
      RAISE EXCEPTION 'item %: componente inválido: %', n, v_comp USING ERRCODE = '22023';
    END IF;
    v_unid := coalesce(e ->> 'unidade',
                       CASE v_comp WHEN 'base' THEN 'centavos' WHEN 'minimo' THEN 'centavos'
                                   WHEN 'nao_comparecimento' THEN 'centavos' WHEN 'por_km' THEN 'centavos_por_km'
                                   WHEN 'comissao_plataforma' THEN 'pontos_base' END);
    IF v_unid IS NULL THEN
      RAISE EXCEPTION 'item %: cancelamento exige unidade (centavos ou pontos_base)', n USING ERRCODE = '22023';
    END IF;
    IF NOT ((v_comp IN ('base','minimo','nao_comparecimento') AND v_unid = 'centavos')
         OR (v_comp = 'por_km' AND v_unid = 'centavos_por_km')
         OR (v_comp = 'cancelamento' AND v_unid IN ('centavos','pontos_base'))
         OR (v_comp = 'comissao_plataforma' AND v_unid = 'pontos_base')) THEN
      RAISE EXCEPTION 'item %: unidade % não serve para o componente %', n, v_unid, v_comp USING ERRCODE = '22023';
    END IF;

    IF jsonb_typeof(e -> 'valor') IS DISTINCT FROM 'number' THEN
      RAISE EXCEPTION 'item %: valor é obrigatório e numérico', n USING ERRCODE = '22023';
    END IF;
    v_valor := (e ->> 'valor')::numeric;
    IF v_valor < 0 OR v_valor <> trunc(v_valor) OR v_valor > 1000000000000 THEN
      RAISE EXCEPTION 'item %: valor deve ser inteiro, de 0 a 10^12, na unidade (centavos, centavos por km ou pontos-base)', n
        USING ERRCODE = '22023';
    END IF;
    IF v_unid = 'pontos_base' AND v_valor > 10000 THEN
      RAISE EXCEPTION 'item %: pontos-base vão até 10000 (100%%)', n USING ERRCODE = '22023';
    END IF;

    v_alvos := (e ? 'uf')::int + (e ? 'regiao')::int + (e ? 'nacional')::int;
    IF v_alvos <> 1 THEN
      RAISE EXCEPTION 'item %: informe exatamente um de uf, regiao ou nacional', n USING ERRCODE = '22023';
    END IF;
    IF e ? 'nacional' THEN
      IF (e -> 'nacional') IS DISTINCT FROM 'true'::jsonb THEN
        RAISE EXCEPTION 'item %: nacional só aceita true', n USING ERRCODE = '22023';
      END IF;
      RETURN QUERY SELECT v_tipo, v_servico, NULL::text, NULL::text, v_comp, v_unid, v_valor::bigint;
    ELSIF e ? 'uf' THEN
      v_uf := e ->> 'uf';
      IF v_uf IS NULL OR uf_codigo_ibge(v_uf) IS NULL THEN
        RAISE EXCEPTION 'item %: UF inválida: %', n, v_uf USING ERRCODE = '22023';
      END IF;
      RETURN QUERY SELECT v_tipo, v_servico, v_uf, NULL::text, v_comp, v_unid, v_valor::bigint;
    ELSE
      FOREACH u IN ARRAY ufs_da_regiao(e ->> 'regiao') LOOP
        RETURN QUERY SELECT v_tipo, v_servico, u, e ->> 'regiao', v_comp, v_unid, v_valor::bigint;
      END LOOP;
    END IF;
  END LOOP;
END $$;

-- Itens gravados de um lote, no mesmo formato de entrada (UF já expandida).
CREATE FUNCTION definicao_itens_json(p_definicao_id uuid) RETURNS jsonb
LANGUAGE sql STABLE AS $$
  SELECT jsonb_agg(
           jsonb_build_object('tipo_parceiro', i.tipo_parceiro_codigo, 'servico', i.servico_codigo,
                              'componente', i.componente, 'unidade', i.unidade, 'valor', i.valor)
           || CASE WHEN i.uf IS NULL THEN jsonb_build_object('nacional', true)
                   ELSE jsonb_build_object('uf', i.uf::text) END
           ORDER BY i.tipo_parceiro_codigo, i.servico_codigo, i.uf NULLS FIRST, i.componente)
    FROM definicao_taxa_item i WHERE i.definicao_id = p_definicao_id
$$;

-- Cálculo (só leitura): para cada item, a regra vigente no escopo exato, a ação e o problema.
CREATE FUNCTION definicao_calculo(p_itens jsonb, p_instante timestamptz)
RETURNS TABLE (tipo_parceiro_codigo text, servico_codigo text, uf text, regiao_codigo text,
               abrangencia text, componente text, unidade text, valor_novo bigint,
               regra_atual_id uuid, situacao_atual text, unidade_atual text, valor_atual bigint,
               fim_atual timestamptz, acao text, problema text)
LANGUAGE sql STABLE AS $$
  WITH i AS (SELECT * FROM definicao_itens(p_itens)),
  d AS (
    SELECT i.*, count(*) OVER (PARTITION BY i.tipo_parceiro_codigo, i.servico_codigo,
                                            coalesce(i.uf, '*'), i.componente) AS repeticoes
      FROM i)
  SELECT d.tipo_parceiro_codigo, d.servico_codigo, d.uf, d.regiao_codigo,
         CASE WHEN d.uf IS NULL THEN 'nacional: vale para todas as UFs sem regra própria'
              ELSE 'UF ' || d.uf END,
         d.componente, d.unidade, d.valor,
         v.id, v.situacao, v.unidade, v.valor, v.fim_vigencia,
         CASE WHEN v.id IS NULL THEN 'criar' ELSE 'definir' END,
         CASE
           WHEN d.repeticoes > 1          THEN 'duplicado'
           WHEN v.situacao = 'definido'   THEN 'ja_definida'
           WHEN EXISTS (SELECT 1 FROM regra_taxa f
                         WHERE f.tipo_parceiro_codigo = d.tipo_parceiro_codigo
                           AND f.servico_codigo = d.servico_codigo
                           AND f.uf::text IS NOT DISTINCT FROM d.uf
                           AND f.componente = d.componente
                           AND f.inicio_vigencia > p_instante
                           AND NOT isempty(tstzrange(f.inicio_vigencia, f.fim_vigencia, '[)')))
                                          THEN 'regra_futura'
         END
    FROM d
    LEFT JOIN LATERAL (
      SELECT r.* FROM regra_taxa r
       WHERE r.tipo_parceiro_codigo = d.tipo_parceiro_codigo
         AND r.servico_codigo = d.servico_codigo
         AND r.uf::text IS NOT DISTINCT FROM d.uf
         AND r.componente = d.componente
         AND tstzrange(r.inicio_vigencia, r.fim_vigencia, '[)') @> p_instante) v ON true
   ORDER BY d.tipo_parceiro_codigo, d.servico_codigo, d.uf NULLS FIRST, d.componente
$$;

-- Recusa o lote se algum item não puder ser aplicado; devolve quantas regras ganharão valor.
CREATE FUNCTION definicao_exigir_aplicavel(p_itens jsonb, p_instante timestamptz) RETURNS integer
LANGUAGE plpgsql STABLE AS $$
DECLARE v_total int; v_dup int; v_def int; v_fut int;
BEGIN
  SELECT count(*),
         count(*) FILTER (WHERE c.problema = 'duplicado'),
         count(*) FILTER (WHERE c.problema = 'ja_definida'),
         count(*) FILTER (WHERE c.problema = 'regra_futura')
    INTO v_total, v_dup, v_def, v_fut
    FROM definicao_calculo(p_itens, p_instante) c;
  IF v_dup > 0 THEN
    RAISE EXCEPTION '% item(ns) repetem o mesmo escopo (atenção à região, que vira uma linha por UF)', v_dup
      USING ERRCODE = '22023';
  END IF;
  IF v_def > 0 THEN
    RAISE EXCEPTION '% item(ns) atingem regra já definida; use o reajuste', v_def USING ERRCODE = 'SC028';
  END IF;
  IF v_fut > 0 THEN
    RAISE EXCEPTION '% item(ns) têm regra futura agendada no escopo; resolva e repita', v_fut USING ERRCODE = 'SC021';
  END IF;
  RETURN v_total;
END $$;

-- Algum item coincide com item de um lote de definição ainda sem decisão? (SC024)
CREATE FUNCTION definicao_exigir_sem_lote_aberto(p_itens jsonb) RETURNS void
LANGUAGE plpgsql STABLE AS $$
DECLARE v_lote uuid;
BEGIN
  SELECT a.definicao_id INTO v_lote
    FROM definicao_itens(p_itens) n
    JOIN definicao_taxa_item a
      ON a.tipo_parceiro_codigo = n.tipo_parceiro_codigo AND a.servico_codigo = n.servico_codigo
     AND a.uf::text IS NOT DISTINCT FROM n.uf AND a.componente = n.componente
   WHERE NOT EXISTS (SELECT 1 FROM definicao_taxa_decisao x WHERE x.definicao_id = a.definicao_id)
   LIMIT 1;
  IF v_lote IS NOT NULL THEN
    RAISE EXCEPTION 'o lote de definição % (ainda sem decisão) já cobre parte deste escopo', v_lote
      USING ERRCODE = 'SC024';
  END IF;
END $$;

-- Quem simula: solicitar_reajuste_taxa ou aprovar_reajuste_taxa.
CREATE FUNCTION exige_solicitar_ou_aprovar_taxa(p_ator uuid) RETURNS void
LANGUAGE plpgsql STABLE AS $$
BEGIN
  IF p_ator IS NULL OR NOT (operador_tem_permissao(p_ator, 'solicitar_reajuste_taxa')
                            OR operador_tem_permissao(p_ator, 'aprovar_reajuste_taxa')) THEN
    RAISE EXCEPTION 'ator % não tem solicitar_reajuste_taxa nem aprovar_reajuste_taxa vigente', p_ator
      USING ERRCODE = 'SC016';
  END IF;
END $$;

-- ---------------------------------------------------------------------
-- Funções da Central (SECURITY DEFINER; EXECUTE só para safetycar_central)
-- ---------------------------------------------------------------------

-- Simulação por itens (antes de solicitar). Não grava nem recusa por problema de item.
CREATE FUNCTION simular_definicao_taxa(p_ator uuid, p_itens jsonb)
RETURNS TABLE (tipo_parceiro_codigo text, servico_codigo text, uf text, regiao_codigo text,
               abrangencia text, componente text, unidade text, valor_novo bigint,
               regra_atual_id uuid, situacao_atual text, unidade_atual text, valor_atual bigint,
               fim_atual timestamptz, acao text, problema text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  PERFORM exige_solicitar_ou_aprovar_taxa(p_ator);
  RETURN QUERY SELECT c.* FROM definicao_calculo(p_itens, clock_timestamp()) c;
END $$;

-- Simulação de um lote já solicitado (com as regras de agora).
CREATE FUNCTION simular_definicao_taxa(p_ator uuid, p_definicao_id uuid)
RETURNS TABLE (tipo_parceiro_codigo text, servico_codigo text, uf text, regiao_codigo text,
               abrangencia text, componente text, unidade text, valor_novo bigint,
               regra_atual_id uuid, situacao_atual text, unidade_atual text, valor_atual bigint,
               fim_atual timestamptz, acao text, problema text)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  PERFORM exige_solicitar_ou_aprovar_taxa(p_ator);
  IF NOT EXISTS (SELECT 1 FROM definicao_taxa WHERE id = p_definicao_id) THEN
    RAISE EXCEPTION 'lote de definição inexistente: %', p_definicao_id USING ERRCODE = '22023';
  END IF;
  RETURN QUERY SELECT c.* FROM definicao_calculo(definicao_itens_json(p_definicao_id), clock_timestamp()) c;
END $$;

-- Solicitação: quem tem solicitar_reajuste_taxa. Não toca em nenhuma regra; recusa cedo o que a
-- aprovação recusaria (a aprovação refaz todas as checagens).
CREATE FUNCTION solicitar_definicao_taxa(p_ator uuid, p_itens jsonb, p_motivo text) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_id uuid; v_n int; v_ator_anterior text := current_setting('safetycar.ator_usuario_id', true);
BEGIN
  PERFORM exige_motivo(p_motivo);
  PERFORM exige_permissao(p_ator, 'solicitar_reajuste_taxa');
  -- Serializa com as outras alterações de regra_taxa: duas solicitações do mesmo escopo
  -- não passam juntas pela checagem de lote em aberto.
  PERFORM pg_advisory_xact_lock(150001);
  v_n := definicao_exigir_aplicavel(p_itens, clock_timestamp());
  PERFORM definicao_exigir_sem_lote_aberto(p_itens);

  PERFORM set_config('safetycar.ator_usuario_id', p_ator::text, true);
  INSERT INTO definicao_taxa (motivo, solicitado_por) VALUES (p_motivo, p_ator) RETURNING id INTO v_id;
  INSERT INTO definicao_taxa_item (definicao_id, tipo_parceiro_codigo, servico_codigo, uf, regiao_codigo,
                                   componente, unidade, valor)
  SELECT v_id, i.tipo_parceiro_codigo, i.servico_codigo, i.uf, i.regiao_codigo, i.componente, i.unidade, i.valor
    FROM definicao_itens(p_itens) i;
  INSERT INTO auditoria (ator_usuario_id, acao, entidade, entidade_id, depois)
  VALUES (p_ator, 'central_definicao_taxa_solicitada', 'definicao_taxa', v_id,
          jsonb_build_object('itens', v_n, 'motivo', p_motivo));
  PERFORM set_config('safetycar.ator_usuario_id', coalesce(v_ator_anterior, ''), true);
  RETURN v_id;
END $$;

-- Aprovação: quem tem aprovar_reajuste_taxa e não é o solicitante (sempre; sem exceção).
-- Numa só transação, encerra as regras "a definir" e cria as definidas. Devolve quantas regras.
CREATE FUNCTION aprovar_definicao_taxa(p_ator uuid, p_definicao_id uuid, p_motivo text) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_solicitante uuid;
  v_itens jsonb;
  v_agora timestamptz;
  v_n integer := 0;
  c record;
  v_ator_anterior text := current_setting('safetycar.ator_usuario_id', true);
BEGIN
  PERFORM exige_motivo(p_motivo);
  PERFORM exige_permissao(p_ator, 'aprovar_reajuste_taxa');

  -- 1) Serializa as alterações de regra_taxa pela Central (mesma chave da 0015).
  PERFORM pg_advisory_xact_lock(150001);

  -- 2) Trava o lote e confere a situação.
  SELECT solicitado_por INTO v_solicitante FROM definicao_taxa WHERE id = p_definicao_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'lote de definição inexistente: %', p_definicao_id USING ERRCODE = '22023';
  END IF;
  IF EXISTS (SELECT 1 FROM definicao_taxa_decisao WHERE definicao_id = p_definicao_id) THEN
    RAISE EXCEPTION 'lote de definição % já foi decidido', p_definicao_id USING ERRCODE = 'SC020';
  END IF;

  -- 3) Quem solicitou não decide.
  IF v_solicitante = p_ator THEN
    RAISE EXCEPTION 'quem solicitou a definição não pode aprová-la' USING ERRCODE = 'SC017';
  END IF;

  -- 4) Trava as regras a encerrar (em ordem de id) e só então lê o relógio; repete com ele.
  v_itens := definicao_itens_json(p_definicao_id);
  PERFORM 1 FROM regra_taxa
   WHERE id IN (SELECT x.regra_atual_id FROM definicao_calculo(v_itens, clock_timestamp()) x)
   ORDER BY id FOR UPDATE;
  v_agora := clock_timestamp();
  PERFORM 1 FROM regra_taxa
   WHERE id IN (SELECT x.regra_atual_id FROM definicao_calculo(v_itens, v_agora) x)
   ORDER BY id FOR UPDATE;

  -- 5) Todas as checagens antes de qualquer escrita.
  PERFORM definicao_exigir_aplicavel(v_itens, v_agora);

  -- 6) Escrita: encerra a "a definir" no instante e cria a definida no mesmo instante.
  PERFORM set_config('safetycar.ator_usuario_id', p_ator::text, true);
  FOR c IN SELECT * FROM definicao_calculo(v_itens, v_agora) LOOP
    IF c.regra_atual_id IS NOT NULL THEN
      UPDATE regra_taxa SET fim_vigencia = v_agora WHERE id = c.regra_atual_id;
    END IF;
    INSERT INTO regra_taxa (tipo_parceiro_codigo, servico_codigo, uf, componente, unidade, valor,
                            base_distancia, situacao, observacao, inicio_vigencia, fim_vigencia,
                            definicao_id, regra_origem_id)
    VALUES (c.tipo_parceiro_codigo, c.servico_codigo, c.uf, c.componente, c.unidade, c.valor_novo,
            CASE WHEN c.componente = 'por_km'
                 THEN coalesce((SELECT r.base_distancia FROM regra_taxa r WHERE r.id = c.regra_atual_id), 'linha_reta')
            END,
            'definido', format('Definição %s', p_definicao_id), v_agora, c.fim_atual,
            p_definicao_id, c.regra_atual_id);
    v_n := v_n + 1;
  END LOOP;

  INSERT INTO definicao_taxa_decisao (definicao_id, situacao, decidido_por, motivo, inicio_efetivo, regras_afetadas)
  VALUES (p_definicao_id, 'aprovado', p_ator, p_motivo, v_agora, v_n);
  INSERT INTO auditoria (ator_usuario_id, acao, entidade, entidade_id, antes, depois)
  VALUES (p_ator, 'central_definicao_taxa_aprovada', 'definicao_taxa', p_definicao_id,
          jsonb_build_object('situacao', 'solicitado'),
          jsonb_build_object('situacao', 'aprovado', 'regras_afetadas', v_n,
                             'inicio_efetivo', v_agora, 'motivo', p_motivo));
  PERFORM set_config('safetycar.ator_usuario_id', coalesce(v_ator_anterior, ''), true);
  RETURN v_n;
END $$;

-- Rejeição: quem tem aprovar_reajuste_taxa e não é o solicitante. Não altera nenhuma regra.
CREATE FUNCTION rejeitar_definicao_taxa(p_ator uuid, p_definicao_id uuid, p_motivo text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_solicitante uuid; v_ator_anterior text := current_setting('safetycar.ator_usuario_id', true);
BEGIN
  PERFORM exige_motivo(p_motivo);
  PERFORM exige_permissao(p_ator, 'aprovar_reajuste_taxa');
  SELECT solicitado_por INTO v_solicitante FROM definicao_taxa WHERE id = p_definicao_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'lote de definição inexistente: %', p_definicao_id USING ERRCODE = '22023';
  END IF;
  IF EXISTS (SELECT 1 FROM definicao_taxa_decisao WHERE definicao_id = p_definicao_id) THEN
    RAISE EXCEPTION 'lote de definição % já foi decidido', p_definicao_id USING ERRCODE = 'SC020';
  END IF;
  IF v_solicitante = p_ator THEN
    RAISE EXCEPTION 'quem solicitou a definição não pode rejeitá-la (cancele)' USING ERRCODE = 'SC017';
  END IF;
  PERFORM set_config('safetycar.ator_usuario_id', p_ator::text, true);
  INSERT INTO definicao_taxa_decisao (definicao_id, situacao, decidido_por, motivo)
  VALUES (p_definicao_id, 'rejeitado', p_ator, p_motivo);
  INSERT INTO auditoria (ator_usuario_id, acao, entidade, entidade_id, antes, depois)
  VALUES (p_ator, 'central_definicao_taxa_rejeitada', 'definicao_taxa', p_definicao_id,
          jsonb_build_object('situacao', 'solicitado'),
          jsonb_build_object('situacao', 'rejeitado', 'motivo', p_motivo));
  PERFORM set_config('safetycar.ator_usuario_id', coalesce(v_ator_anterior, ''), true);
END $$;

-- Cancelamento: o próprio solicitante (operador ativo) ou quem tem aprovar_reajuste_taxa.
CREATE FUNCTION cancelar_definicao_taxa(p_ator uuid, p_definicao_id uuid, p_motivo text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE v_solicitante uuid; v_ator_anterior text := current_setting('safetycar.ator_usuario_id', true);
BEGIN
  PERFORM exige_motivo(p_motivo);
  SELECT solicitado_por INTO v_solicitante FROM definicao_taxa WHERE id = p_definicao_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'lote de definição inexistente: %', p_definicao_id USING ERRCODE = '22023';
  END IF;
  IF p_ator IS NOT DISTINCT FROM v_solicitante THEN
    PERFORM exige_operador_ativo(p_ator);
  ELSE
    PERFORM exige_permissao(p_ator, 'aprovar_reajuste_taxa');
  END IF;
  IF EXISTS (SELECT 1 FROM definicao_taxa_decisao WHERE definicao_id = p_definicao_id) THEN
    RAISE EXCEPTION 'lote de definição % já foi decidido', p_definicao_id USING ERRCODE = 'SC020';
  END IF;
  PERFORM set_config('safetycar.ator_usuario_id', p_ator::text, true);
  INSERT INTO definicao_taxa_decisao (definicao_id, situacao, decidido_por, motivo)
  VALUES (p_definicao_id, 'cancelado', p_ator, p_motivo);
  INSERT INTO auditoria (ator_usuario_id, acao, entidade, entidade_id, antes, depois)
  VALUES (p_ator, 'central_definicao_taxa_cancelada', 'definicao_taxa', p_definicao_id,
          jsonb_build_object('situacao', 'solicitado'),
          jsonb_build_object('situacao', 'cancelado', 'motivo', p_motivo));
  PERFORM set_config('safetycar.ator_usuario_id', coalesce(v_ator_anterior, ''), true);
END $$;

-- ---------------------------------------------------------------------
-- Privilégios
-- ---------------------------------------------------------------------

REVOKE ALL ON FUNCTION
  ufs_da_regiao(text),
  definicao_itens(jsonb),
  definicao_itens_json(uuid),
  definicao_calculo(jsonb, timestamptz),
  definicao_exigir_aplicavel(jsonb, timestamptz),
  definicao_exigir_sem_lote_aberto(jsonb),
  exige_solicitar_ou_aprovar_taxa(uuid),
  simular_definicao_taxa(uuid, jsonb),
  simular_definicao_taxa(uuid, uuid),
  solicitar_definicao_taxa(uuid, jsonb, text),
  aprovar_definicao_taxa(uuid, uuid, text),
  rejeitar_definicao_taxa(uuid, uuid, text),
  cancelar_definicao_taxa(uuid, uuid, text)
FROM PUBLIC;

-- Central: lê regiões, lotes, itens e decisões; age só pelas funções.
GRANT SELECT ON regiao, regiao_uf, definicao_taxa, definicao_taxa_item, definicao_taxa_decisao,
                vw_definicao_taxa
  TO safetycar_central;
GRANT EXECUTE ON FUNCTION
  simular_definicao_taxa(uuid, jsonb),
  simular_definicao_taxa(uuid, uuid),
  solicitar_definicao_taxa(uuid, jsonb, text),
  aprovar_definicao_taxa(uuid, uuid, text),
  rejeitar_definicao_taxa(uuid, uuid, text),
  cancelar_definicao_taxa(uuid, uuid, text)
TO safetycar_central;

-- App: nada novo. Continua só lendo regra_taxa (inclusive a coluna definicao_id).
