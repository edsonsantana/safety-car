-- 04 — Tomador: perfil, CPF (hash), veículo e contato de emergência

INSERT INTO usuario (id, keycloak_sub, email, perfil) VALUES
  ('00000000-0000-4000-8000-000000000011', gen_random_uuid(), 't1@exemplo.invalid', 'tomador'),
  ('00000000-0000-4000-8000-000000000012', gen_random_uuid(), 't2@exemplo.invalid', 'tomador'),
  ('00000000-0000-4000-8000-000000000013', gen_random_uuid(), 'p1@exemplo.invalid', 'parceiro');

SELECT pg_temp.aceita($$
  INSERT INTO tomador (usuario_id, nome_completo, cpf_cifrado, cpf_hash)
  VALUES ('00000000-0000-4000-8000-000000000011', '[TESTE] Tomador Um',
          '\xdeadbeef', pg_temp.hmac_teste('12345678909'))$$,
  'tomador com CPF cifrado + hash');

SELECT pg_temp.espera_erro($$
  INSERT INTO tomador (usuario_id, nome_completo, cpf_cifrado, cpf_hash)
  VALUES ('00000000-0000-4000-8000-000000000012', '[TESTE] Tomador Dois',
          '\xcafebabe', pg_temp.hmac_teste('12345678909'))$$,
  '23505', 'cpf_hash duplicado entre tomadores é rejeitado');

SELECT pg_temp.espera_erro($$
  INSERT INTO tomador (usuario_id, nome_completo, cpf_hash)
  VALUES ('00000000-0000-4000-8000-000000000012', '[TESTE] Tomador Dois', pg_temp.hmac_teste('98765432100'))$$,
  '23514', 'cpf_hash sem cpf_cifrado é rejeitado');

SELECT pg_temp.aceita($$
  INSERT INTO tomador (usuario_id, nome_completo)
  VALUES ('00000000-0000-4000-8000-000000000012', '[TESTE] Tomador Dois')$$,
  'tomador sem CPF (decisão de quando exigir está pendente)');

SELECT pg_temp.espera_erro($$
  INSERT INTO tomador (usuario_id, nome_completo)
  VALUES ('00000000-0000-4000-8000-000000000013', '[TESTE] Parceiro como tomador')$$,
  'SC001', 'usuário de perfil parceiro não pode ser tomador');

SELECT pg_temp.aceita($$
  INSERT INTO veiculo (tomador_id, placa, marca, modelo, categoria) VALUES
    ('00000000-0000-4000-8000-000000000011', 'ABC1234', 'Fictícia', 'Modelo A', 'passeio'),
    ('00000000-0000-4000-8000-000000000011', 'BRA2E19', 'Fictícia', 'Modelo B', 'moto'),
    ('00000000-0000-4000-8000-000000000012', 'ABC1234', 'Fictícia', 'Modelo A', 'passeio')$$,
  'veículos com placa antiga e Mercosul; mesma placa em tomadores diferentes');

SELECT pg_temp.espera_erro($$
  INSERT INTO veiculo (tomador_id, placa, marca, modelo, categoria)
  VALUES ('00000000-0000-4000-8000-000000000011', 'ABC1234', 'Fictícia', 'Repetido', 'passeio')$$,
  '23505', 'mesma placa duas vezes para o mesmo tomador é rejeitada');

SELECT pg_temp.espera_erro($$
  INSERT INTO veiculo (tomador_id, placa, marca, modelo, categoria)
  VALUES ('00000000-0000-4000-8000-000000000011', 'XYZ9876', 'Fictícia', 'Barco', 'lancha')$$,
  '23514', 'categoria de veículo fora da lista é rejeitada');

SELECT pg_temp.espera_erro($$
  INSERT INTO contato_emergencia (tomador_id, nome, celular_e164)
  VALUES ('00000000-0000-4000-8000-000000000011', '[TESTE] Contato', '(11) 99999-0000')$$,
  '23514', 'contato de emergência com telefone fora de E.164 é rejeitado');
