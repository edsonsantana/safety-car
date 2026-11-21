import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { describe, expect, test, vi } from 'vitest';
import { useSessao } from './contexto.ts';
import type { ServicoAutenticacao } from './oidc.ts';
import { ProvedorSessao } from './ProvedorSessao.tsx';

function servicoFalso(parcial: Partial<ServicoAutenticacao> = {}): ServicoAutenticacao {
  return {
    restaurar: vi.fn(() => Promise.resolve(undefined)),
    concluirEntrada: vi.fn(() => Promise.resolve({ token: 'token-ficticio', destino: '/central' })),
    entrar: vi.fn(() => Promise.resolve()),
    criarConta: vi.fn(() => Promise.resolve()),
    sair: vi.fn(() => Promise.resolve()),
    aoMudarToken: vi.fn(() => () => undefined),
    ...parcial,
  };
}

function Mostrar() {
  const sessao = useSessao();
  return (
    <>
      <p>acesso: {JSON.stringify(sessao.acesso)}</p>
      <button type="button" onClick={() => void sessao.concluirEntrada()}>
        concluir
      </button>
    </>
  );
}

function stubMe(perfil: string, status: string) {
  const fetch = vi.fn(() =>
    Promise.resolve(new Response(JSON.stringify({ perfil, status }), { status: 200 })),
  );
  vi.stubGlobal('fetch', fetch);
  return fetch;
}

describe('ProvedorSessao', () => {
  test('sem sessão no Keycloak: anônimo, sem chamar o /me', async () => {
    const fetch = stubMe('tomador', 'ativo');
    render(
      <ProvedorSessao servico={servicoFalso()} cadastroHabilitado={false} caminhoInicial="/">
        <Mostrar />
      </ProvedorSessao>,
    );
    expect(await screen.findByText('acesso: {"tipo":"anonimo"}')).toBeInTheDocument();
    expect(fetch).not.toHaveBeenCalled();
  });

  test('depois de um F5: a renovação silenciosa recupera o token e o perfil vem do /me', async () => {
    stubMe('central', 'ativo');
    const servico = servicoFalso({ restaurar: vi.fn(() => Promise.resolve('token-ficticio')) });
    render(
      <ProvedorSessao servico={servico} cadastroHabilitado={false} caminhoInicial="/central">
        <Mostrar />
      </ProvedorSessao>,
    );
    expect(screen.getByText('acesso: {"tipo":"verificando"}')).toBeInTheDocument();
    expect(
      await screen.findByText('acesso: {"tipo":"liberado","perfil":"central"}'),
    ).toBeInTheDocument();
  });

  test('em /entrando não tenta a renovação: quem conclui é a tela de retorno', async () => {
    stubMe('tomador', 'pendente');
    const servico = servicoFalso();
    render(
      <ProvedorSessao servico={servico} cadastroHabilitado={false} caminhoInicial="/entrando">
        <Mostrar />
      </ProvedorSessao>,
    );
    expect(servico.restaurar).not.toHaveBeenCalled();
    await userEvent.click(screen.getByRole('button', { name: 'concluir' }));
    expect(
      await screen.findByText('acesso: {"tipo":"pendente","perfil":"tomador"}'),
    ).toBeInTheDocument();
  });

  test('token removido (expirado ou saída): volta a anônimo', async () => {
    stubMe('tomador', 'ativo');
    let avisar: (token: string | undefined) => void = () => undefined;
    const servico = servicoFalso({
      restaurar: vi.fn(() => Promise.resolve('token-ficticio')),
      aoMudarToken: vi.fn((aviso: (token: string | undefined) => void) => {
        avisar = aviso;
        return () => undefined;
      }),
    });
    render(
      <ProvedorSessao servico={servico} cadastroHabilitado={false} caminhoInicial="/">
        <Mostrar />
      </ProvedorSessao>,
    );
    await screen.findByText('acesso: {"tipo":"liberado","perfil":"tomador"}');
    avisar(undefined);
    await waitFor(() => {
      expect(screen.getByText('acesso: {"tipo":"anonimo"}')).toBeInTheDocument();
    });
  });
});
