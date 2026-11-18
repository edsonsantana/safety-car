import { render, screen } from '@testing-library/react';
import { describe, expect, test, vi } from 'vitest';
import { axe } from 'vitest-axe';
import { EstadoApi } from './EstadoApi.tsx';

function respostaJson(status: number, corpo: unknown) {
  return new Response(JSON.stringify(corpo), { status });
}

describe('EstadoApi', () => {
  test('começa em "verificando", numa região role="status"', () => {
    vi.stubGlobal('fetch', () => new Promise(() => undefined));
    render(<EstadoApi />);
    expect(screen.getByRole('status')).toHaveTextContent('Verificando a conexão com o servidor');
  });

  test('ok', async () => {
    vi.stubGlobal('fetch', () => Promise.resolve(respostaJson(200, { status: 'ok', banco: 'ok' })));
    render(<EstadoApi />);
    expect(await screen.findByText('Servidor e banco de dados funcionando.')).toBeInTheDocument();
  });

  test('banco indisponível (503)', async () => {
    vi.stubGlobal('fetch', () =>
      Promise.resolve(respostaJson(503, { status: 'degradado', banco: 'indisponivel' })),
    );
    render(<EstadoApi />);
    expect(await screen.findByText(/banco de dados está indisponível/)).toBeInTheDocument();
  });

  test('API indisponível (rede)', async () => {
    vi.stubGlobal('fetch', () => Promise.reject(new TypeError('Failed to fetch')));
    const { container } = render(<EstadoApi />);
    expect(await screen.findByText(/Servidor indisponível/)).toBeInTheDocument();
    expect(await axe(container)).toHaveNoViolations();
  });

  test('cancela a consulta ao desmontar', () => {
    let sinal: AbortSignal | undefined;
    vi.stubGlobal('fetch', (_url: string, init: RequestInit) => {
      sinal = init.signal ?? undefined;
      return new Promise(() => undefined);
    });
    const { unmount } = render(<EstadoApi />);
    unmount();
    expect(sinal?.aborted).toBe(true);
  });
});
