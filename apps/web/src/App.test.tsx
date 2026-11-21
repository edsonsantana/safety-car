import { render, screen } from '@testing-library/react';
import { expect, test, vi } from 'vitest';
import { App } from './App.tsx';
import type { ServicoAutenticacao } from './autenticacao/oidc.ts';

test('a aplicação abre na tela de entrada quando não há sessão no Keycloak', async () => {
  const servico: ServicoAutenticacao = {
    restaurar: vi.fn(() => Promise.resolve(undefined)),
    concluirEntrada: vi.fn(() => Promise.reject(new Error('não usado'))),
    entrar: vi.fn(() => Promise.resolve()),
    criarConta: vi.fn(() => Promise.resolve()),
    sair: vi.fn(() => Promise.resolve()),
    aoMudarToken: vi.fn(() => () => undefined),
  };
  render(<App servico={servico} />);
  expect(await screen.findByRole('button', { name: 'Entrar' })).toBeInTheDocument();
  expect(screen.getByRole('heading', { level: 1, name: 'Safety Car' })).toBeInTheDocument();
  expect(servico.restaurar).toHaveBeenCalledOnce();
});
