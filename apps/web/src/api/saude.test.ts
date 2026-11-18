import { describe, expect, test, vi } from 'vitest';
import { consultarSaude } from './saude.ts';

function respostaJson(status: number, corpo: unknown) {
  return new Response(JSON.stringify(corpo), {
    status,
    headers: { 'content-type': 'application/json' },
  });
}

describe('consultarSaude', () => {
  test('200 com status ok: ok', async () => {
    const fetch = vi.fn(() => Promise.resolve(respostaJson(200, { status: 'ok', banco: 'ok' })));
    vi.stubGlobal('fetch', fetch);
    expect(await consultarSaude()).toBe('ok');
    expect(fetch).toHaveBeenCalledWith(
      '/api/saude',
      expect.objectContaining({ cache: 'no-store' }),
    );
  });

  test('503 com banco indisponível: banco_indisponivel', async () => {
    vi.stubGlobal('fetch', () =>
      Promise.resolve(respostaJson(503, { status: 'degradado', banco: 'indisponivel' })),
    );
    expect(await consultarSaude()).toBe('banco_indisponivel');
  });

  test('erro de rede: api_indisponivel', async () => {
    vi.stubGlobal('fetch', () => Promise.reject(new TypeError('Failed to fetch')));
    expect(await consultarSaude()).toBe('api_indisponivel');
  });

  test('proxy sem a API (502, corpo não JSON): api_indisponivel', async () => {
    vi.stubGlobal('fetch', () => Promise.resolve(new Response('Bad Gateway', { status: 502 })));
    expect(await consultarSaude()).toBe('api_indisponivel');
  });

  test('503 sem o corpo da API: api_indisponivel', async () => {
    vi.stubGlobal('fetch', () => Promise.resolve(respostaJson(503, { erro: 'x' })));
    expect(await consultarSaude()).toBe('api_indisponivel');
  });

  test('tempo esgotado: api_indisponivel', async () => {
    // fetch que só termina quando o sinal é abortado, como o de verdade.
    vi.stubGlobal('fetch', (_url: string, init: RequestInit) => {
      return new Promise((_, rejeitar) => {
        init.signal?.addEventListener('abort', () => {
          rejeitar(new DOMException('tempo esgotado', 'TimeoutError'));
        });
      });
    });
    expect(await consultarSaude({ tempoLimiteMs: 20 })).toBe('api_indisponivel');
  });

  test('cancelamento por quem chamou é repassado, não vira "API indisponível"', async () => {
    vi.stubGlobal('fetch', (_url: string, init: RequestInit) => {
      return new Promise((_, rejeitar) => {
        init.signal?.addEventListener('abort', () => {
          rejeitar(new DOMException('cancelado', 'AbortError'));
        });
      });
    });
    const controle = new AbortController();
    const consulta = consultarSaude({ sinal: controle.signal });
    controle.abort();
    await expect(consulta).rejects.toThrow('cancelado');
  });
});
