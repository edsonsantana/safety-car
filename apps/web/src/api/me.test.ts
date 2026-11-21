import { describe, expect, test, vi } from 'vitest';
import { consultarMe } from './me.ts';

// Token fictício: a API é simulada pelo fetch.
const TOKEN = 'token-ficticio';

function responder(status: number, corpo?: unknown) {
  const fetch = vi.fn(() =>
    Promise.resolve(new Response(corpo === undefined ? null : JSON.stringify(corpo), { status })),
  );
  vi.stubGlobal('fetch', fetch);
  return fetch;
}

describe('consultarMe', () => {
  test('envia o token no Authorization, sem cache', async () => {
    const fetch = responder(200, { perfil: 'tomador', status: 'ativo' });
    await consultarMe(TOKEN);
    expect(fetch).toHaveBeenCalledWith(
      '/api/me',
      expect.objectContaining({
        cache: 'no-store',
        headers: expect.objectContaining({ authorization: `Bearer ${TOKEN}` }) as unknown,
      }),
    );
  });

  test.each(['tomador', 'parceiro', 'central'] as const)('ativo (%s): liberado', async (perfil) => {
    responder(200, { perfil, status: 'ativo' });
    expect(await consultarMe(TOKEN)).toEqual({ tipo: 'liberado', perfil });
  });

  test('pendente: separado do liberado', async () => {
    responder(200, { perfil: 'parceiro', status: 'pendente' });
    expect(await consultarMe(TOKEN)).toEqual({ tipo: 'pendente', perfil: 'parceiro' });
  });

  test('403: restrito', async () => {
    responder(403, { erro: { codigo: 'acesso_restrito', mensagem: 'Acesso restrito.' } });
    expect(await consultarMe(TOKEN)).toEqual({ tipo: 'restrito' });
  });

  test.each([401, 500, 503])('%i: indisponível', async (status) => {
    responder(status, { erro: { codigo: 'x', mensagem: 'x' } });
    expect(await consultarMe(TOKEN)).toEqual({ tipo: 'indisponivel' });
  });

  test.each([
    ['perfil desconhecido', { perfil: 'administrador', status: 'ativo' }],
    ['status desconhecido', { perfil: 'tomador', status: 'suspenso' }],
    ['corpo que não é objeto', 'ok'],
  ])('resposta fora do formato (%s): indisponível', async (_, corpo) => {
    responder(200, corpo);
    expect(await consultarMe(TOKEN)).toEqual({ tipo: 'indisponivel' });
  });

  test('falha de rede: indisponível', async () => {
    vi.stubGlobal('fetch', () => Promise.reject(new TypeError('fetch failed')));
    expect(await consultarMe(TOKEN)).toEqual({ tipo: 'indisponivel' });
  });
});
