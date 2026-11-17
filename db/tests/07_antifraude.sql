-- 07 — Antifraude base: meio de pagamento, dispositivo, sinal de risco e bloqueio

INSERT INTO usuario (id, keycloak_sub, email, perfil) VALUES
  ('00000000-0000-4000-8000-000000000031', gen_random_uuid(), 'af1@exemplo.invalid', 'tomador'),
  ('00000000-0000-4000-8000-000000000032', gen_random_uuid(), 'af2@exemplo.invalid', 'tomador'),
  ('00000000-0000-4000-8000-000000000033', gen_random_uuid(), 'afc@exemplo.invalid', 'central');

-- ---------- Meio de pagamento ----------
SELECT pg_temp.confere(
  NOT EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_name = 'meio_pagamento'
                 AND column_name ~ '(numero|pan|cvv|validade)'),
  'meio_pagamento não tem coluna para número, CVV ou validade do cartão');
SELECT pg_temp.aceita($$
  INSERT INTO meio_pagamento (usuario_id, psp, token_psp, bandeira, final_4, cartao_fingerprint_hash)
  VALUES ('00000000-0000-4000-8000-000000000031', 'psp_ficticio', 'tok_teste_1', 'visa', '4242',
          pg_temp.hmac_teste('fp-cartao-1'))$$,
  'cartão tokenizado com bandeira e final 4');
SELECT pg_temp.espera_erro($$
  INSERT INTO meio_pagamento (usuario_id, psp, token_psp, bandeira, final_4)
  VALUES ('00000000-0000-4000-8000-000000000032', 'psp_ficticio', 'tok_teste_1', 'visa', '4242')$$,
  '23505', 'mesmo token do mesmo PSP duas vezes é rejeitado');
SELECT pg_temp.espera_erro($$
  INSERT INTO meio_pagamento (usuario_id, psp, token_psp, bandeira, final_4)
  VALUES ('00000000-0000-4000-8000-000000000031', 'psp_ficticio', 'tok_teste_2', 'visa', '4111111111111111')$$,
  '22001', 'final_4 com mais de 4 caracteres (ex.: número completo) é rejeitado');
SELECT pg_temp.espera_erro($$
  INSERT INTO meio_pagamento (usuario_id, psp, token_psp, bandeira, final_4)
  VALUES ('00000000-0000-4000-8000-000000000031', 'psp_ficticio', 'tok_teste_3', 'visa', '42a2')$$,
  '23514', 'final_4 não numérico é rejeitado');
SELECT pg_temp.espera_erro($$
  INSERT INTO meio_pagamento (usuario_id, psp, token_psp, bandeira, final_4)
  VALUES ('00000000-0000-4000-8000-000000000031', 'psp_ficticio', 'tok_teste_4', 'cartaox', '1234')$$,
  '23514', 'bandeira fora da lista é rejeitada');

-- ---------- Dispositivo ----------
INSERT INTO dispositivo (id, usuario_id, fingerprint_hash) VALUES
  ('00000000-0000-4000-8000-0000000000d1', '00000000-0000-4000-8000-000000000031', pg_temp.hmac_teste('aparelho-1')),
  ('00000000-0000-4000-8000-0000000000d2', '00000000-0000-4000-8000-000000000032', pg_temp.hmac_teste('aparelho-1'));
SELECT pg_temp.confere(
  (SELECT count(DISTINCT usuario_id) = 2 FROM dispositivo WHERE fingerprint_hash = pg_temp.hmac_teste('aparelho-1')),
  'mesmo aparelho em duas contas é registrado e localizável pelo hash');
SELECT pg_temp.espera_erro($$
  INSERT INTO dispositivo (usuario_id, fingerprint_hash)
  VALUES ('00000000-0000-4000-8000-000000000031', pg_temp.hmac_teste('aparelho-1'))$$,
  '23505', 'mesmo aparelho duas vezes para o mesmo usuário é rejeitado');

-- ---------- Sinal de risco ----------
SELECT pg_temp.aceita($$
  INSERT INTO sinal_risco (usuario_id, dispositivo_id, tipo, severidade, detalhes)
  VALUES ('00000000-0000-4000-8000-000000000032', '00000000-0000-4000-8000-0000000000d2',
          'multiplas_contas_dispositivo', 'alta', '{"contas": 2}')$$,
  'sinal de risco com detalhes em jsonb');
SELECT pg_temp.espera_erro($$
  INSERT INTO sinal_risco (tipo, severidade) VALUES ('outro', 'baixa')$$,
  '23514', 'sinal de risco sem usuário nem dispositivo é rejeitado');
SELECT pg_temp.espera_erro($$
  INSERT INTO sinal_risco (usuario_id, tipo, severidade)
  VALUES ('00000000-0000-4000-8000-000000000031', 'outro', 'gravissima')$$,
  '23514', 'severidade fora da lista é rejeitada');

-- ---------- Bloqueio ----------
SELECT pg_temp.espera_erro($$
  INSERT INTO bloqueio (tipo, valor_hash, motivo, criado_por)
  VALUES ('cpf_hash', pg_temp.hmac_teste('12345678909'), 'teste', '00000000-0000-4000-8000-000000000031')$$,
  'SC001', 'bloqueio só pode ser criado por usuário central');
SELECT pg_temp.espera_erro($$
  INSERT INTO bloqueio (tipo, valor_hash, motivo, criado_por)
  VALUES ('ip', pg_temp.hmac_teste('10.0.0.1'), 'teste', '00000000-0000-4000-8000-000000000033')$$,
  '23514', 'tipo de bloqueio fora da lista é rejeitado');

INSERT INTO bloqueio (tipo, valor_hash, motivo, criado_por, criado_em, expira_em) VALUES
  ('cpf_hash',    pg_temp.hmac_teste('12345678909'), '[TESTE] fraude confirmada', '00000000-0000-4000-8000-000000000033', now(), NULL),
  ('dispositivo', pg_temp.hmac_teste('aparelho-1'),  '[TESTE] temporário',        '00000000-0000-4000-8000-000000000033', now(), now() + interval '1 day'),
  ('email',       pg_temp.hmac_teste('x@exemplo.invalid'), '[TESTE] expirado',    '00000000-0000-4000-8000-000000000033', now() - interval '2 days', now() - interval '1 day');

SELECT pg_temp.confere(esta_bloqueado('cpf_hash', pg_temp.hmac_teste('12345678909')),
  'bloqueio permanente de CPF vigente');
SELECT pg_temp.confere(esta_bloqueado('dispositivo', pg_temp.hmac_teste('aparelho-1')),
  'bloqueio temporário de dispositivo vigente');
SELECT pg_temp.confere(NOT esta_bloqueado('email', pg_temp.hmac_teste('x@exemplo.invalid')),
  'bloqueio expirado não vale');
SELECT pg_temp.confere(NOT esta_bloqueado('celular', pg_temp.hmac_teste('12345678909')),
  'bloqueio é por tipo: mesmo hash em outro tipo não bloqueia');
SELECT pg_temp.espera_erro($$
  INSERT INTO bloqueio (tipo, valor_hash, motivo, criado_por, expira_em)
  VALUES ('celular', pg_temp.hmac_teste('+5511900000001'), 'teste', '00000000-0000-4000-8000-000000000033', now() - interval '1 hour')$$,
  '23514', 'bloqueio com expiração anterior à criação é rejeitado');
