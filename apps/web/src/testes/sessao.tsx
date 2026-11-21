// Apoio dos testes: sessão falsa (sem Keycloak) e renderização com rotas em memória.
import { render } from '@testing-library/react';
import type { ReactNode } from 'react';
import { MemoryRouter } from 'react-router';
import { vi } from 'vitest';
import { ContextoSessao } from '../autenticacao/contexto.ts';
import type { Sessao } from '../autenticacao/tipos.ts';

export function sessaoFalsa(parcial: Partial<Sessao> = {}): Sessao {
  return {
    acesso: { tipo: 'anonimo' },
    cadastroHabilitado: false,
    entrar: vi.fn(() => Promise.resolve()),
    criarConta: vi.fn(() => Promise.resolve()),
    concluirEntrada: vi.fn(() => Promise.resolve('/')),
    recarregarPerfil: vi.fn(() => Promise.resolve()),
    sair: vi.fn(() => Promise.resolve()),
    obterToken: () => undefined,
    ...parcial,
  };
}

interface Opcoes {
  sessao?: Sessao;
  caminho?: string;
  /** location.state da entrada inicial (ex.: { destino }). */
  estado?: unknown;
}

export function renderizar(
  ui: ReactNode,
  { sessao = sessaoFalsa(), caminho = '/', estado }: Opcoes = {},
) {
  return render(
    <ContextoSessao value={sessao}>
      <MemoryRouter initialEntries={[{ pathname: caminho, state: estado }]}>{ui}</MemoryRouter>
    </ContextoSessao>,
  );
}
