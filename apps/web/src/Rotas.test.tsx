import { screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { beforeEach, describe, expect, test, vi } from 'vitest';
import { axe } from 'vitest-axe';
import type { Acesso } from './autenticacao/tipos.ts';
import { Rotas } from './Rotas.tsx';
import { renderizar, sessaoFalsa } from './testes/sessao.tsx';

// /componentes consulta GET /saude; aqui a consulta fica pendente.
beforeEach(() => {
  vi.stubGlobal('fetch', () => new Promise(() => undefined));
});

// /componentes é carregada sob demanda: com a suíte inteira em paralelo, a primeira carga
// pode passar do 1 s padrão do findBy.
const ESPERA_CARGA = { timeout: 10_000 };
const LIMITE_TESTE_MS = 15_000;

const CENTRAL: Acesso = { tipo: 'liberado', perfil: 'central' };

/** Por padrão, um usuário ativo da Central (as áreas protegidas abrem). */
function abrir(caminho: string, acesso: Acesso = CENTRAL) {
  return renderizar(<Rotas />, { caminho, sessao: sessaoFalsa({ acesso }) });
}

describe('rotas', () => {
  test('/ sem sessão é a tela de entrada', () => {
    abrir('/', { tipo: 'anonimo' });
    expect(screen.getByRole('heading', { level: 1, name: 'Safety Car' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Entrar' })).toBeInTheDocument();
  });

  test('/entrar (antigo) leva à tela de entrada', () => {
    abrir('/entrar', { tipo: 'anonimo' });
    expect(screen.getByRole('button', { name: 'Entrar' })).toBeInTheDocument();
  });

  test.each([
    ['/tomador', 'tomador', 'Início do tomador'],
    ['/parceiro', 'parceiro', 'Início do parceiro'],
    ['/central', 'central', 'Painel da Central'],
  ] as const)('%s abre para o perfil %s', (caminho, perfil, titulo) => {
    abrir(caminho, { tipo: 'liberado', perfil });
    expect(screen.getByRole('heading', { level: 1, name: titulo })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Sair' })).toBeInTheDocument();
  });

  test.each(['/tomador', '/parceiro', '/central'])('%s sem sessão volta à entrada', (caminho) => {
    abrir(caminho, { tipo: 'anonimo' });
    expect(screen.getByRole('button', { name: 'Entrar' })).toBeInTheDocument();
  });

  test('/central com perfil tomador: Acesso restrito', () => {
    abrir('/central', { tipo: 'liberado', perfil: 'tomador' });
    expect(screen.getByRole('heading', { name: 'Esta área é restrita' })).toBeInTheDocument();
  });

  test.each([
    ['/cadastro', 'Cadastro'],
    ['/verificacao', 'Verificação'],
    ['/central', 'Painel da Central'],
    ['/nao-existe', 'Página não encontrada'],
  ])('%s mostra o <h1> "%s" e o título da aba', async (caminho, titulo) => {
    abrir(caminho);
    expect(screen.getByRole('heading', { level: 1, name: titulo })).toBeInTheDocument();
    await waitFor(() => {
      expect(document.title).toBe(`${titulo} · Safety Car`);
    });
  });

  test(
    '/componentes existe em desenvolvimento (carregada sob demanda), com o estado da API',
    async () => {
      abrir('/componentes');
      expect(
        await screen.findByRole('heading', { level: 1, name: 'Componentes' }, ESPERA_CARGA),
      ).toBeInTheDocument();
      expect(screen.getByText('Verificando a conexão com o servidor…')).toBeInTheDocument();
    },
    LIMITE_TESTE_MS,
  );

  test.each(['/', '/central'])('%s tem "Pular para o conteúdo" como primeiro foco', async (c) => {
    abrir(c, c === '/' ? { tipo: 'anonimo' } : CENTRAL);
    await userEvent.tab();
    const link = screen.getByRole('link', { name: 'Pular para o conteúdo' });
    expect(link).toHaveFocus();
    expect(link).toHaveAttribute('href', '#conteudo');
    expect(screen.getByRole('main')).toHaveAttribute('id', 'conteudo');
  });

  test.each(['/', '/central', '/componentes'])(
    '%s sem falhas de acessibilidade',
    async (c) => {
      // Em "/", sem sessão (com sessão a entrada redireciona para o início do perfil).
      const { container } = abrir(c, c === '/' ? { tipo: 'anonimo' } : CENTRAL);
      await screen.findByRole('heading', { level: 1 }, ESPERA_CARGA);
      expect(await axe(container)).toHaveNoViolations();
    },
    LIMITE_TESTE_MS,
  );
});

describe('LayoutMovel', () => {
  test('cabeçalho com o logotipo leva ao início', () => {
    abrir('/cadastro');
    expect(screen.getByRole('link', { name: 'Safety Car' })).toHaveAttribute('href', '/');
    expect(screen.getByRole('main')).toHaveClass('max-w-[390px]');
  });
});

describe('LayoutPainel', () => {
  test('menu lateral com o item "Painel" marcado como página atual', () => {
    abrir('/central');
    const menu = screen.getByRole('navigation', { name: 'Menu da Central' });
    expect(menu).toContainElement(screen.getByRole('link', { name: 'Painel' }));
    expect(screen.getByRole('link', { name: 'Painel' })).toHaveAttribute('aria-current', 'page');
  });

  test('o botão abre e fecha a gaveta; Esc também fecha', async () => {
    abrir('/central');
    const botao = screen.getByRole('button', { name: 'Abrir menu' });
    expect(botao).toHaveAttribute('aria-expanded', 'false');
    expect(botao).toHaveAttribute('aria-controls', 'menu-central');

    await userEvent.click(botao);
    expect(screen.getByRole('button', { name: 'Fechar menu' })).toHaveAttribute(
      'aria-expanded',
      'true',
    );

    await userEvent.keyboard('{Escape}');
    expect(screen.getByRole('button', { name: 'Abrir menu' })).toHaveAttribute(
      'aria-expanded',
      'false',
    );
  });

  test('clicar num item do menu fecha a gaveta', async () => {
    abrir('/central');
    await userEvent.click(screen.getByRole('button', { name: 'Abrir menu' }));
    await userEvent.click(screen.getByRole('link', { name: 'Painel' }));
    expect(screen.getByRole('button', { name: 'Abrir menu' })).toHaveAttribute(
      'aria-expanded',
      'false',
    );
  });
});
