import { InMemoryWebStorage, WebStorageStateStore } from 'oidc-client-ts';
import { describe, expect, test } from 'vitest';
import { lerConfigKeycloak } from './config.ts';
import { CAMINHO_RENOVACAO, CAMINHO_RETORNO, opcoesOidc } from './oidc.ts';
import { destinoSeguro } from './tipos.ts';

describe('destinoSeguro', () => {
  test.each(['/', '/central', '/tomador?aba=1'])('aceita caminho interno %s', (destino) => {
    expect(destinoSeguro(destino)).toBe(destino);
  });

  test.each([
    'https://exemplo.invalid/',
    '//exemplo.invalid/',
    '/\\exemplo.invalid',
    'central',
    '',
    undefined,
    42,
  ])('troca %s por "/"', (destino) => {
    expect(destinoSeguro(destino)).toBe('/');
  });
});

describe('lerConfigKeycloak', () => {
  test('padrões de desenvolvimento (porta 8180, cadastro desligado)', () => {
    expect(lerConfigKeycloak({})).toEqual({
      url: 'http://localhost:8180',
      realm: 'safetycar-dev',
      clientId: 'safetycar-web',
      cadastroHabilitado: false,
    });
  });

  test('lê as variáveis VITE_* e tira a barra final da URL', () => {
    expect(
      lerConfigKeycloak({
        VITE_KEYCLOAK_URL: 'http://localhost:9999/',
        VITE_KEYCLOAK_REALM: 'outro-realm',
        VITE_KEYCLOAK_CLIENT_ID: 'outro-client',
        VITE_CADASTRO_HABILITADO: 'true',
      }),
    ).toEqual({
      url: 'http://localhost:9999',
      realm: 'outro-realm',
      clientId: 'outro-client',
      cadastroHabilitado: true,
    });
  });
});

describe('opcoesOidc', () => {
  const opcoes = opcoesOidc(lerConfigKeycloak({}), 'http://localhost:5173');

  test('realm, client público e URIs iguais às do client no Keycloak', () => {
    expect(opcoes.authority).toBe('http://localhost:8180/realms/safetycar-dev');
    expect(opcoes.client_id).toBe('safetycar-web');
    expect(opcoes).not.toHaveProperty('client_secret');
    expect(opcoes.response_type).toBe('code');
    expect(opcoes.redirect_uri).toBe(`http://localhost:5173${CAMINHO_RETORNO}`);
    expect(opcoes.silent_redirect_uri).toBe(`http://localhost:5173${CAMINHO_RENOVACAO}`);
    expect(opcoes.post_logout_redirect_uri).toBe('http://localhost:5173/');
    // PKCE é o padrão do oidc-client-ts; não pode ser desligado aqui.
    expect(opcoes.disablePKCE).toBeUndefined();
    expect(opcoes.monitorSession).toBe(false);
  });

  test('tokens só em memória; o sessionStorage guarda só o estado da ida ao Keycloak', async () => {
    expect(opcoes.userStore).toBeInstanceOf(WebStorageStateStore);
    // O userStore grava num InMemoryWebStorage: nada vai para localStorage/sessionStorage.
    await opcoes.userStore?.set('usuario', 'valor-ficticio');
    expect(Object.keys(localStorage)).toHaveLength(0);
    expect(Object.keys(sessionStorage)).toHaveLength(0);
    expect((opcoes.userStore as unknown as { _store: unknown })._store).toBeInstanceOf(
      InMemoryWebStorage,
    );
    expect((opcoes.stateStore as unknown as { _store: unknown })._store).toBe(
      window.sessionStorage,
    );
  });
});
