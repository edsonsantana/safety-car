-- 06 — Geo: área de atuação, posição atual (upsert), view de posição válida e parceiros_proximos
-- Ponto de busca: Praça da Sé, São Paulo (-23.5503, -46.6339). Parceiros fictícios [TESTE].

-- Cria um parceiro com 1 tipo, 1 viatura, 1 serviço e posição com idade p_idade_s segundos.
CREATE FUNCTION pg_temp.cria_parceiro(p_nome text, p_base_cnpj text, p_tipo text, p_servico text,
                                      p_status text, p_lat float8, p_lng float8, p_idade_s int)
RETURNS uuid LANGUAGE plpgsql AS $f$
DECLARE v_parceiro uuid; v_viatura uuid;
BEGIN
  INSERT INTO parceiro (tipo_pessoa, cnpj, nome, email_comercial, telefone_e164,
                        responsavel_nome, responsavel_cpf_cifrado, responsavel_cpf_hash)
  VALUES ('pj', p_base_cnpj || cnpj_dv(p_base_cnpj), p_nome, 'geo@exemplo.invalid', '+5511900000200',
          '[TESTE] Responsável', '\x10', pg_temp.hmac_teste('39053344705'))
  RETURNING id INTO v_parceiro;
  INSERT INTO parceiro_tipo (parceiro_id, tipo_codigo) VALUES (v_parceiro, p_tipo);
  INSERT INTO parceiro_viatura (parceiro_id, placa, tipo)
  VALUES (v_parceiro, 'TST' || lpad((floor(random() * 10000))::int::text, 4, '0'), 'outro')
  RETURNING id INTO v_viatura;
  INSERT INTO parceiro_servico (parceiro_id, servico_codigo) VALUES (v_parceiro, p_servico);
  UPDATE parceiro SET status_credenciamento = p_status WHERE id = v_parceiro;
  INSERT INTO parceiro_posicao_atual (viatura_id, localizacao, precisao_m, atualizado_em)
  VALUES (v_viatura, ST_SetSRID(ST_MakePoint(p_lng, p_lat), 4326)::geography, 8,
          now() - make_interval(secs => p_idade_s));
  RETURN v_parceiro;
END $f$;

CREATE TEMP TABLE p (rotulo text PRIMARY KEY, id uuid);
INSERT INTO p VALUES
  ('A_valido_1km',       pg_temp.cria_parceiro('[TESTE] A válido ~1 km',      '910000000001', 'guincho',  'guincho_leve', 'aprovado',   -23.5413, -46.6339,  10)),
  ('F_valido_3km_170s',  pg_temp.cria_parceiro('[TESTE] F válido ~3 km 170 s', '910000000006', 'guincho',  'guincho_leve', 'aprovado',   -23.5233, -46.6339, 170)),
  ('B_fora_do_raio',     pg_temp.cria_parceiro('[TESTE] B a ~50 km',          '910000000002', 'guincho',  'guincho_leve', 'aprovado',   -23.1000, -46.6339,  10)),
  ('C_posicao_velha',    pg_temp.cria_parceiro('[TESTE] C posição de 300 s',  '910000000003', 'guincho',  'guincho_leve', 'aprovado',   -23.5458, -46.6339, 300)),
  ('D_nao_aprovado',     pg_temp.cria_parceiro('[TESTE] D em análise',        '910000000004', 'guincho',  'guincho_leve', 'em_analise', -23.5458, -46.6339,  10)),
  ('E_outro_servico',    pg_temp.cria_parceiro('[TESTE] E chaveiro',          '910000000005', 'chaveiro', 'chaveiro',     'aprovado',   -23.5458, -46.6339,  10));

-- ---------- View de posição válida ----------
SELECT pg_temp.confere(
  (SELECT array_agg(p.rotulo ORDER BY p.rotulo) FROM vw_parceiro_posicao_valida v JOIN p ON p.id = v.parceiro_id)
    = ARRAY['A_valido_1km','B_fora_do_raio','E_outro_servico','F_valido_3km_170s'],
  'view exclui posição com mais de 180 s e parceiro não aprovado');

-- ---------- parceiros_proximos ----------
SELECT pg_temp.confere(
  (SELECT array_agg(p.rotulo ORDER BY r.ordem)
     FROM (SELECT x.*, row_number() OVER () AS ordem
             FROM parceiros_proximos(-23.5503, -46.6339, 10000, 'guincho_leve') x) r
     JOIN p ON p.id = r.parceiro_id)
    = ARRAY['A_valido_1km','F_valido_3km_170s'],
  'guincho_leve a 10 km: só A e F, nessa ordem (fora do raio, posição velha, não aprovado e outro serviço excluídos)');

SELECT pg_temp.confere(
  (SELECT distancia_m BETWEEN 990 AND 1010
     FROM parceiros_proximos(-23.5503, -46.6339, 10000, 'guincho_leve') x
     JOIN p ON p.id = x.parceiro_id AND p.rotulo = 'A_valido_1km'),
  'distância geodésica de A ~1.000 m (0,009° de latitude)');

SELECT pg_temp.confere(
  (SELECT array_agg(p.rotulo) FROM parceiros_proximos(-23.5503, -46.6339, 10000, 'chaveiro') x
     JOIN p ON p.id = x.parceiro_id) = ARRAY['E_outro_servico'],
  'serviço chaveiro: só E');

SELECT pg_temp.confere(
  (SELECT count(*) = 3 FROM parceiros_proximos(-23.5503, -46.6339, 60000, 'guincho_leve')),
  'raio de 60 km inclui B (A, F e B)');

SELECT pg_temp.confere(
  (SELECT count(*) = 0 FROM parceiros_proximos(-23.5503, -46.6339, 10000, 'pneu')),
  'serviço sem parceiro na região: nenhum resultado');

UPDATE parceiro_viatura SET ativa = false
 WHERE parceiro_id = (SELECT id FROM p WHERE rotulo = 'F_valido_3km_170s');
SELECT pg_temp.confere(
  (SELECT count(*) = 1 FROM parceiros_proximos(-23.5503, -46.6339, 10000, 'guincho_leve')),
  'viatura inativa sai da busca');

SELECT pg_temp.espera_erro($$SELECT * FROM parceiros_proximos(-91, -46.6, 1000, 'guincho_leve')$$,
  '22023', 'latitude fora de ±90 é rejeitada');
SELECT pg_temp.espera_erro($$SELECT * FROM parceiros_proximos(-23.5, -181, 1000, 'guincho_leve')$$,
  '22023', 'longitude fora de ±180 é rejeitada');
SELECT pg_temp.espera_erro($$SELECT * FROM parceiros_proximos(-23.5, -46.6, 0, 'guincho_leve')$$,
  '22023', 'raio zero é rejeitado');
SELECT pg_temp.espera_erro($$SELECT * FROM parceiros_proximos(-23.5, -46.6, 1000, 'teletransporte')$$,
  '22023', 'serviço inexistente é rejeitado');

-- ---------- Posição atual: upsert, uma linha por viatura ----------
SELECT pg_temp.aceita($$
  INSERT INTO parceiro_posicao_atual (viatura_id, localizacao, precisao_m, velocidade_kmh, rumo_graus)
  SELECT pv.id, ST_SetSRID(ST_MakePoint(-46.6340, -23.5500), 4326)::geography, 5, 30, 90
    FROM parceiro_viatura pv JOIN p ON p.id = pv.parceiro_id AND p.rotulo = 'C_posicao_velha'
  ON CONFLICT (viatura_id) DO UPDATE
     SET localizacao = EXCLUDED.localizacao, precisao_m = EXCLUDED.precisao_m,
         velocidade_kmh = EXCLUDED.velocidade_kmh, rumo_graus = EXCLUDED.rumo_graus$$,
  'upsert de posição na mesma viatura');
SELECT pg_temp.confere(
  (SELECT count(*) = 1 AND bool_and(pa.atualizado_em = now())
     FROM parceiro_posicao_atual pa JOIN parceiro_viatura pv ON pv.id = pa.viatura_id
     JOIN p ON p.id = pv.parceiro_id AND p.rotulo = 'C_posicao_velha'),
  'continua uma linha por viatura, com atualizado_em renovado');
SELECT pg_temp.confere(
  EXISTS (SELECT 1 FROM vw_parceiro_posicao_valida v JOIN p ON p.id = v.parceiro_id AND p.rotulo = 'C_posicao_velha'),
  'posição renovada volta a ser válida');
SELECT pg_temp.espera_erro($$
  UPDATE parceiro_posicao_atual SET rumo_graus = 360$$,
  '23514', 'rumo de 360 graus é rejeitado (0 a 359,9)');
SELECT pg_temp.espera_erro($$
  UPDATE parceiro_posicao_atual SET velocidade_kmh = -1$$,
  '23514', 'velocidade negativa é rejeitada');

-- ---------- Área de atuação ----------
INSERT INTO parceiro (id, tipo_pessoa, cnpj, nome, email_comercial, telefone_e164)
VALUES ('00000000-0000-4000-8000-0000000000e1', 'pj', '920000000001' || cnpj_dv('920000000001'),
        '[TESTE] Seguros e Mecânica', 'sm@exemplo.invalid', '+5511900000300');
INSERT INTO parceiro_tipo VALUES ('00000000-0000-4000-8000-0000000000e1', 'seguros');

SELECT pg_temp.espera_erro($$
  INSERT INTO parceiro_area_atuacao (parceiro_id, uf)
  VALUES ('00000000-0000-4000-8000-0000000000e1', 'SP')$$,
  'SC005', 'área de atuação para parceiro só de seguros é rejeitada');

INSERT INTO parceiro_tipo VALUES ('00000000-0000-4000-8000-0000000000e1', 'mecanica');
SELECT pg_temp.aceita($$
  INSERT INTO parceiro_area_atuacao (parceiro_id, uf, municipio_ibge, centro, raio_m)
  VALUES ('00000000-0000-4000-8000-0000000000e1', 'SP', 3550308,
          ST_SetSRID(ST_MakePoint(-46.6339, -23.5503), 4326)::geography, 40000)$$,
  'área com município e círculo (40 km) para parceiro com tipo de assistência');
SELECT pg_temp.aceita($$
  INSERT INTO parceiro_area_atuacao (parceiro_id, uf)
  VALUES ('00000000-0000-4000-8000-0000000000e1', 'RJ')$$,
  'área de UF inteira, sem recorte geográfico');
SELECT pg_temp.espera_erro($$
  INSERT INTO parceiro_area_atuacao (parceiro_id, uf)
  VALUES ('00000000-0000-4000-8000-0000000000e1', 'RJ')$$,
  '23505', 'mesma UF inteira duas vezes é rejeitada (NULLS NOT DISTINCT)');
SELECT pg_temp.espera_erro($$
  INSERT INTO parceiro_area_atuacao (parceiro_id, uf, centro)
  VALUES ('00000000-0000-4000-8000-0000000000e1', 'MG',
          ST_SetSRID(ST_MakePoint(-43.9, -19.9), 4326)::geography)$$,
  '23514', 'centro sem raio é rejeitado');
SELECT pg_temp.espera_erro($$
  INSERT INTO parceiro_area_atuacao (parceiro_id, uf, municipio_ibge)
  VALUES ('00000000-0000-4000-8000-0000000000e1', 'MG', 3550308)$$,
  '23514', 'município de outra UF é rejeitado');
SELECT pg_temp.confere(
  EXISTS (SELECT 1 FROM parceiro_area_atuacao
           WHERE ST_DWithin(centro, ST_SetSRID(ST_MakePoint(-46.70, -23.60), 4326)::geography, raio_m)),
  'ponto a ~9 km do centro está dentro da área de 40 km');
SELECT pg_temp.espera_erro($$
  DELETE FROM parceiro_tipo
   WHERE parceiro_id = '00000000-0000-4000-8000-0000000000e1' AND tipo_codigo = 'mecanica'$$,
  'SC006', 'remover o único tipo de assistência de parceiro com área de atuação é bloqueado');

-- ---------- Endereço geocodificado ----------
SELECT pg_temp.aceita($$
  INSERT INTO endereco (cep, logradouro, numero, bairro, municipio, uf, localizacao)
  VALUES ('01001000', '[TESTE] Praça Fictícia', '1', 'Sé', 'São Paulo', 'SP',
          ST_SetSRID(ST_MakePoint(-46.6339, -23.5503), 4326)::geography)$$,
  'endereço com localização geográfica');
