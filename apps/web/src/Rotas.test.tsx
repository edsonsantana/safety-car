import { render, screen, waitFor } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { MemoryRouter } from 'react-router';
import { beforeEach, describe, expect, test, vi } from 'vitest';
import { axe } from 'vitest-axe';
import { Rotas } from './Rotas.tsx';

// A página inicial consulta GET /saude; aqui a consulta fica pendente.
beforeEach(() => {
  vi.stubGlobal('fetch', () => new Promise(() => undefined));
});

function abrir(caminho: string) {
  return render(
    <MemoryRouter initialEntries={[caminho]}>
      <Rotas />
    </MemoryRouter>,
  );
}

describe('rotas', () => {
  test.each([
    ['/', 'Início'],
    ['/cadastro', 'Cadastro'],
    ['/entrar', 'Entrar'],
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

  test('/componentes existe em desenvolvimento (carregada sob demanda)', async () => {
    abrir('/componentes');
    expect(
      await screen.findByRole('heading', { level: 1, name: 'Componentes' }),
    ).toBeInTheDocument();
  });

  test.each(['/', '/central'])('%s tem "Pular para o conteúdo" como primeiro foco', async (c) => {
    abrir(c);
    await userEvent.tab();
    const link = screen.getByRole('link', { name: 'Pular para o conteúdo' });
    expect(link).toHaveFocus();
    expect(link).toHaveAttribute('href', '#conteudo');
    expect(screen.getByRole('main')).toHaveAttribute('id', 'conteudo');
  });

  test.each(['/', '/central', '/componentes'])('%s sem falhas de acessibilidade', async (c) => {
    const { container } = abrir(c);
    await screen.findByRole('heading', { level: 1 });
    expect(await axe(container)).toHaveNoViolations();
  });
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
