import assert from 'node:assert/strict';
import { describe, test } from 'node:test';

import { carregarConfig, ErroConfiguracao } from '../../src/config.ts';

const SENHA = 'senha-ficticia-de-teste';
const ISSUER = 'http://localhost:8180/realms/safetycar-dev';
const SENHA_CENTRAL = 'outra-senha-ficticia-de-teste';
const MINIMO = {
  API_DB_SENHA: SENHA,
  KEYCLOAK_ISSUER: ISSUER,
  API_CENTRAL_DB_SENHA: SENHA_CENTRAL,
};

function erroDe(ambiente: NodeJS.ProcessEnv): ErroConfiguracao {
  try {
    carregarConfig(ambiente);
  } catch (erro) {
    assert.ok(erro instanceof ErroConfiguracao);
    return erro;
  }
  assert.fail('a configuração deveria ter sido recusada');
}

describe('carregarConfig', () => {
  test('aplica os padrões e usa o safetycar_app', () => {
    const config = carregarConfig(MINIMO);
    assert.deepEqual(config, {
      http: { host: '127.0.0.1', porta: 3000 },
      log: { nivel: 'info' },
      banco: {
        host: '127.0.0.1',
        porta: 5432,
        nome: 'safetycar',
        usuario: 'safetycar_app',
        senha: SENHA,
      },
      keycloak: { issuer: ISSUER, audience: 'safetycar-api', azp: 'safetycar-web' },
      central: {
        banco: {
          host: '127.0.0.1',
          porta: 5432,
          nome: 'safetycar',
          usuario: 'safetycar_central',
          senha: SENHA_CENTRAL,
        },
        azp: 'safetycar-central',
        acr: '2',
        otpRecenteSegundos: 600,
      },
    });
  });

  test('falha com mensagem clara quando falta a senha (vazia conta como ausente)', () => {
    const erro = erroDe({ ...MINIMO, API_DB_SENHA: '   ' });
    assert.deepEqual(erro.problemas, ['API_DB_SENHA: obrigatória']);
    assert.match(erro.message, /Configuração inválida da API/);
    assert.match(erro.message, /\.env\.example/);
  });

  for (const papel of ['safetycar_migrator', 'postgres']) {
    test(`recusa o papel ${papel}`, () => {
      const erro = erroDe({ ...MINIMO, API_DB_USUARIO: papel });
      assert.equal(erro.problemas.length, 1);
      assert.match(erro.problemas[0] ?? '', /^API_DB_USUARIO: use o papel safetycar_app/);
    });
  }

  test('o pool do app não aceita o papel da Central', () => {
    const erro = erroDe({ ...MINIMO, API_DB_USUARIO: 'safetycar_central' });
    assert.match(erro.problemas[0] ?? '', /^API_DB_USUARIO: use o papel safetycar_app/);
  });

  for (const papel of ['safetycar_app', 'safetycar_migrator', 'postgres']) {
    test(`o pool da Central recusa o papel ${papel}`, () => {
      const erro = erroDe({ ...MINIMO, API_CENTRAL_DB_USUARIO: papel });
      assert.deepEqual(erro.problemas, [
        'API_CENTRAL_DB_USUARIO: use o papel safetycar_central; o pool da Central não aceita outro papel',
      ]);
    });
  }

  test('a senha da Central é obrigatória e não aparece na mensagem', () => {
    const erro = erroDe({ ...MINIMO, API_CENTRAL_DB_SENHA: '' });
    assert.deepEqual(erro.problemas, ['API_CENTRAL_DB_SENHA: obrigatória']);
    const outro = erroDe({ ...MINIMO, API_PORTA: '0' });
    assert.ok(!outro.message.includes(SENHA_CENTRAL));
  });

  test('o client da Central precisa ser diferente do client do app', () => {
    const erro = erroDe({ ...MINIMO, KEYCLOAK_CENTRAL_CLIENT_ID: 'safetycar-web' });
    assert.deepEqual(erro.problemas, [
      'KEYCLOAK_CENTRAL_CLIENT_ID: deve ser diferente de KEYCLOAK_CLIENT_ID (token do app não entra na Central)',
    ]);
  });

  test('client e acr da Central configuráveis', () => {
    const config = carregarConfig({
      ...MINIMO,
      KEYCLOAK_CENTRAL_CLIENT_ID: 'central-x',
      KEYCLOAK_CENTRAL_ACR: 'otp',
    });
    assert.equal(config.central.azp, 'central-x');
    assert.equal(config.central.acr, 'otp');
  });

  test('lista todos os problemas de uma vez e nunca mostra os valores', () => {
    const erro = erroDe({
      API_PORTA: '99999',
      API_DB_PORTA: 'abc',
      API_LOG_NIVEL: 'verboso',
      API_DB_USUARIO: 'safetycar_migrator',
    });
    assert.deepEqual(
      erro.problemas.map((p) => p.split(':')[0]),
      [
        'API_PORTA',
        'API_LOG_NIVEL',
        'API_DB_PORTA',
        'API_DB_USUARIO',
        'API_DB_SENHA',
        'KEYCLOAK_ISSUER',
        'API_CENTRAL_DB_SENHA',
      ],
    );
    assert.doesNotMatch(erro.message, /99999|abc|verboso/);
  });

  test('não repete a senha na mensagem de erro', () => {
    const erro = erroDe({ ...MINIMO, API_PORTA: '0' });
    assert.ok(!erro.message.includes(SENHA));
  });

  test('KEYCLOAK_ISSUER precisa ser URL http(s); a barra final é removida', () => {
    const erro = erroDe({ ...MINIMO, KEYCLOAK_ISSUER: 'localhost:8180' });
    assert.match(erro.problemas[0] ?? '', /^KEYCLOAK_ISSUER: deve ser uma URL http\(s\)/);
    const config = carregarConfig({ ...MINIMO, KEYCLOAK_ISSUER: `${ISSUER}/` });
    assert.equal(config.keycloak.issuer, ISSUER);
  });
});
