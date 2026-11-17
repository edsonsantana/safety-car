-- 02 — Formatos: placa, CEP, telefone, UF, município, CNPJ, HMAC

-- Placa
SELECT pg_temp.aceita($$SELECT 'ABC1234'::dom_placa$$, 'placa no padrão antigo (ABC1234)');
SELECT pg_temp.aceita($$SELECT 'BRA2E19'::dom_placa$$, 'placa Mercosul (BRA2E19)');
SELECT pg_temp.espera_erro($$SELECT 'abc1234'::dom_placa$$, '23514', 'placa em minúsculas é rejeitada');
SELECT pg_temp.espera_erro($$SELECT 'ABC-1234'::dom_placa$$, '23514', 'placa com hífen é rejeitada');
SELECT pg_temp.espera_erro($$SELECT 'AB12345'::dom_placa$$, '23514', 'placa com 2 letras é rejeitada');
SELECT pg_temp.espera_erro($$SELECT 'ABC1D2E'::dom_placa$$, '23514', 'placa com letra na última posição é rejeitada');

-- CEP
SELECT pg_temp.aceita($$SELECT '01001000'::dom_cep$$, 'CEP com 8 dígitos');
SELECT pg_temp.espera_erro($$SELECT '01001-000'::dom_cep$$, '23514', 'CEP com máscara é rejeitado');
SELECT pg_temp.espera_erro($$SELECT '0100100'::dom_cep$$, '23514', 'CEP com 7 dígitos é rejeitado');

-- Telefone E.164
SELECT pg_temp.aceita($$SELECT '+5511999990000'::dom_e164$$, 'celular em E.164');
SELECT pg_temp.espera_erro($$SELECT '11999990000'::dom_e164$$, '23514', 'telefone sem + é rejeitado');
SELECT pg_temp.espera_erro($$SELECT '+55 11 99999-0000'::dom_e164$$, '23514', 'telefone com espaços/hífen é rejeitado');
SELECT pg_temp.espera_erro($$SELECT '+0551199999'::dom_e164$$, '23514', 'telefone com código de país iniciado em 0 é rejeitado');
SELECT pg_temp.espera_erro($$SELECT '+5511999990000123'::dom_e164$$, '23514', 'telefone com mais de 15 dígitos é rejeitado');

-- UF e município
SELECT pg_temp.espera_erro($$SELECT 'XX'::dom_uf$$, '23514', 'UF inexistente é rejeitada');
SELECT pg_temp.espera_erro($$SELECT 355030::dom_municipio_ibge$$, '23514', 'código IBGE com 6 dígitos é rejeitado');
SELECT pg_temp.aceita($$
  INSERT INTO endereco (cep, logradouro, numero, bairro, municipio, municipio_ibge, uf)
  VALUES ('01001000', '[TESTE] Praça Fictícia', '1', 'Centro', 'São Paulo', 3550308, 'SP')$$,
  'endereço com município IBGE da própria UF');
SELECT pg_temp.espera_erro($$
  INSERT INTO endereco (cep, logradouro, numero, bairro, municipio, municipio_ibge, uf)
  VALUES ('20000000', '[TESTE] Rua Fictícia', '1', 'Centro', 'Rio de Janeiro', 3550308, 'RJ')$$,
  '23514', 'endereço com município de outra UF é rejeitado');

-- CNPJ (numérico e alfanumérico, com DV)
SELECT pg_temp.aceita($$SELECT '11222333000181'::dom_cnpj$$, 'CNPJ numérico válido');
SELECT pg_temp.aceita($$SELECT '12ABC34501DE35'::dom_cnpj$$, 'CNPJ alfanumérico válido (exemplo da Receita)');
SELECT pg_temp.espera_erro($$SELECT '11222333000182'::dom_cnpj$$, '23514', 'CNPJ numérico com DV errado é rejeitado');
SELECT pg_temp.espera_erro($$SELECT '12ABC34501DE36'::dom_cnpj$$, '23514', 'CNPJ alfanumérico com DV errado é rejeitado');
SELECT pg_temp.espera_erro($$SELECT '11.222.333/0001-81'::dom_cnpj$$, '23514', 'CNPJ com máscara é rejeitado');
SELECT pg_temp.espera_erro($$SELECT '12abc34501de35'::dom_cnpj$$, '23514', 'CNPJ alfanumérico em minúsculas é rejeitado');
SELECT pg_temp.espera_erro($$SELECT '00000000000000'::dom_cnpj$$, '23514', 'CNPJ com todos os caracteres iguais é rejeitado');
SELECT pg_temp.espera_erro($$SELECT '1122233300018A'::dom_cnpj$$, '23514', 'CNPJ com letra no DV é rejeitado');

-- HMAC
SELECT pg_temp.espera_erro($$SELECT '\x0102'::bytea::dom_hmac$$, '23514', 'hash com tamanho diferente de 32 bytes é rejeitado');
