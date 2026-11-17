-- 0005 — Fundação geoespacial.
-- Todas as coordenadas em geography(Point, 4326) (WGS 84, graus; distâncias em metros).
-- Distâncias calculadas aqui são GEODÉSICAS (linha reta sobre o elipsoide), NÃO rota viária.
-- Sem histórico de posições nesta fase: a retenção de GPS depende de decisão de privacidade (LGPD).

-- ---------------------------------------------------------------------
-- Endereço geocodificado (opcional)
-- ---------------------------------------------------------------------

ALTER TABLE endereco ADD COLUMN localizacao geography(Point, 4326);
-- Consulta prevista: endereços (ex.: base do parceiro) próximos de um ponto.
CREATE INDEX ix_endereco_localizacao ON endereco USING gist (localizacao);

-- ---------------------------------------------------------------------
-- Área de atuação do parceiro: UF/município + círculo opcional (centro + raio)
--   - município nulo = UF inteira
--   - centro/raio nulos = sem recorte geográfico além de UF/município
-- Escolha centro+raio (e não polígono): é como o parceiro declara a área
-- ("atendo até 40 km da base"), é simples de cadastrar e ST_DWithin(centro, ponto, raio_m)
-- usa o índice GiST diretamente. Polígono pode entrar depois como coluna nova.
-- ---------------------------------------------------------------------

CREATE TABLE parceiro_area_atuacao (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  parceiro_id    uuid NOT NULL REFERENCES parceiro(id),
  uf             dom_uf NOT NULL,
  municipio_ibge dom_municipio_ibge,
  centro         geography(Point, 4326),
  raio_m         integer CHECK (raio_m > 0),
  criado_em      timestamptz NOT NULL DEFAULT now(),
  atualizado_em  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT ck_area_centro_raio CHECK ((centro IS NULL) = (raio_m IS NULL)),
  CONSTRAINT ck_area_municipio_da_uf
    CHECK (municipio_ibge IS NULL OR municipio_ibge / 100000 = uf_codigo_ibge(uf)),
  -- Também serve de índice para "áreas do parceiro X".
  CONSTRAINT uq_area_parceiro_local UNIQUE NULLS NOT DISTINCT (parceiro_id, uf, municipio_ibge)
);
-- Consulta prevista: "quais parceiros atendem este ponto?" (ST_DWithin(centro, ponto, raio_m))
CREATE INDEX ix_area_atuacao_centro ON parceiro_area_atuacao USING gist (centro);
CREATE TRIGGER tg_area_atuacao_atualizado_em BEFORE UPDATE ON parceiro_area_atuacao
  FOR EACH ROW EXECUTE FUNCTION definir_atualizado_em();
-- Só parceiros de tipos de assistência rodoviária (SC005, função da 0004).
CREATE TRIGGER tg_area_atuacao_assistencia BEFORE INSERT OR UPDATE OF parceiro_id ON parceiro_area_atuacao
  FOR EACH ROW EXECUTE FUNCTION exige_parceiro_assistencia();

-- Remoção de tipo passa a considerar também a área de atuação.
CREATE OR REPLACE FUNCTION parceiro_tipo_remocao() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM parceiro_viatura WHERE parceiro_id = OLD.parceiro_id AND ativa)
     AND NOT parceiro_tem_tipo_com(OLD.parceiro_id, 'permite_viatura') THEN
    RAISE EXCEPTION 'parceiro % tem viatura ativa e ficaria sem tipo que permita viatura', OLD.parceiro_id
      USING ERRCODE = 'SC006';
  END IF;
  IF (EXISTS (SELECT 1 FROM parceiro_servico      WHERE parceiro_id = OLD.parceiro_id)
      OR EXISTS (SELECT 1 FROM parceiro_area_atuacao WHERE parceiro_id = OLD.parceiro_id))
     AND NOT parceiro_tem_tipo_com(OLD.parceiro_id, 'assistencia_rodoviaria') THEN
    RAISE EXCEPTION 'parceiro % tem serviços ou área de atuação e ficaria sem tipo de assistência', OLD.parceiro_id
      USING ERRCODE = 'SC006';
  END IF;
  RETURN NULL;
END $$;

-- ---------------------------------------------------------------------
-- Posição atual: UMA linha por viatura (upsert). Sem histórico.
--   INSERT ... ON CONFLICT (viatura_id) DO UPDATE SET localizacao = EXCLUDED.localizacao, ...
--   atualizado_em = hora do SERVIDOR na gravação (o trigger ignora valor enviado no UPDATE).
-- ---------------------------------------------------------------------

CREATE TABLE parceiro_posicao_atual (
  viatura_id     uuid PRIMARY KEY REFERENCES parceiro_viatura(id),
  localizacao    geography(Point, 4326) NOT NULL,
  precisao_m     numeric(8,1) CHECK (precisao_m >= 0),
  velocidade_kmh numeric(5,1) CHECK (velocidade_kmh >= 0),
  rumo_graus     numeric(4,1) CHECK (rumo_graus >= 0 AND rumo_graus < 360),
  atualizado_em  timestamptz NOT NULL DEFAULT now()
);
-- Consulta prevista: busca por proximidade (ST_DWithin) em parceiros_proximos().
CREATE INDEX ix_posicao_atual_localizacao ON parceiro_posicao_atual USING gist (localizacao);
CREATE TRIGGER tg_posicao_atual_atualizado_em BEFORE UPDATE ON parceiro_posicao_atual
  FOR EACH ROW EXECUTE FUNCTION definir_atualizado_em();

-- ---------------------------------------------------------------------
-- Posições válidas: até 180 s (regra herdada da v8: posição mais antiga não é
-- apresentada como atual), viatura ativa, parceiro aprovado e de tipo de assistência.
-- ---------------------------------------------------------------------

CREATE VIEW vw_parceiro_posicao_valida WITH (security_invoker = true) AS
SELECT p.id            AS parceiro_id,
       p.nome          AS parceiro_nome,
       pp.viatura_id,
       pp.localizacao,
       pp.precisao_m,
       pp.velocidade_kmh,
       pp.rumo_graus,
       pp.atualizado_em
  FROM parceiro_posicao_atual pp
  JOIN parceiro_viatura pv ON pv.id = pp.viatura_id AND pv.ativa
  JOIN parceiro p          ON p.id  = pv.parceiro_id AND p.status_credenciamento = 'aprovado'
 WHERE pp.atualizado_em >= now() - interval '180 seconds'
   AND parceiro_tem_tipo_com(p.id, 'assistencia_rodoviaria');

COMMENT ON VIEW vw_parceiro_posicao_valida IS
  'Posições com até 180 s, de viaturas ativas de parceiros aprovados de tipo de assistência rodoviária.';

-- ---------------------------------------------------------------------
-- Parceiros próximos de um ponto que oferecem um serviço.
-- Uma linha por VIATURA (um parceiro pode aparecer com mais de uma viatura),
-- ordenada pela distância GEODÉSICA (linha reta) — não é rota viária nem ETA.
-- ---------------------------------------------------------------------

CREATE FUNCTION parceiros_proximos(lat double precision, lng double precision,
                                   raio_m integer, servico text)
RETURNS TABLE (parceiro_id   uuid,
               parceiro_nome text,
               viatura_id    uuid,
               distancia_m   double precision,
               precisao_m    numeric,
               atualizado_em timestamptz)
LANGUAGE plpgsql STABLE AS $$
#variable_conflict use_column
DECLARE
  v_ponto geography;
BEGIN
  IF parceiros_proximos.lat IS NULL OR parceiros_proximos.lat NOT BETWEEN -90 AND 90 THEN
    RAISE EXCEPTION 'latitude inválida: %', parceiros_proximos.lat USING ERRCODE = '22023';
  END IF;
  IF parceiros_proximos.lng IS NULL OR parceiros_proximos.lng NOT BETWEEN -180 AND 180 THEN
    RAISE EXCEPTION 'longitude inválida: %', parceiros_proximos.lng USING ERRCODE = '22023';
  END IF;
  IF parceiros_proximos.raio_m IS NULL OR parceiros_proximos.raio_m <= 0 THEN
    RAISE EXCEPTION 'raio inválido: % (metros, maior que zero)', parceiros_proximos.raio_m USING ERRCODE = '22023';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM servico_catalogo sc WHERE sc.codigo = parceiros_proximos.servico AND sc.ativo) THEN
    RAISE EXCEPTION 'serviço inexistente ou inativo: %', parceiros_proximos.servico USING ERRCODE = '22023';
  END IF;

  v_ponto := ST_SetSRID(ST_MakePoint(parceiros_proximos.lng, parceiros_proximos.lat), 4326)::geography;

  RETURN QUERY
  SELECT v.parceiro_id,
         v.parceiro_nome,
         v.viatura_id,
         ST_Distance(v.localizacao, v_ponto) AS distancia_m,
         v.precisao_m,
         v.atualizado_em
    FROM vw_parceiro_posicao_valida v
   WHERE ST_DWithin(v.localizacao, v_ponto, parceiros_proximos.raio_m)
     AND EXISTS (SELECT 1 FROM parceiro_servico ps
                  WHERE ps.parceiro_id = v.parceiro_id
                    AND ps.servico_codigo = parceiros_proximos.servico
                    AND ps.ativo)
   ORDER BY 4, v.atualizado_em DESC;
END $$;

COMMENT ON FUNCTION parceiros_proximos(double precision, double precision, integer, text) IS
  'Viaturas de parceiros aprovados com posição válida (<= 180 s) a até raio_m metros do ponto e que '
  'oferecem o serviço. Distância GEODÉSICA (linha reta), não rota viária.';
