import { screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { Route, Routes } from 'react-router';
import { describe, expect, test, vi } from 'vitest';
import { axe } from 'vitest-axe';
import { renderizar, sessaoFalsa } from '../testes/sessao.tsx';
import { Entrada } from './Entrada.tsx';

function abrir(sessao = sessaoFalsa(), estado?: unknown) {
  return renderizar(
    <Routes>
      <Route index element={<Entrada />} />
      <Route path="central" element={<p>área da central</p>} />
      <Route path="acesso-restrito" element={<p>tela de acesso restrito</p>} />
    </Routes>,
    { sessao, estado },
  );
}

describe('Entrada', () => {
  test('mostra a marca, a faixa, o logo, ENTRAR e o rodapé de urgência', () => {
    abrir();
    expect(screen.getByRole('heading', { level: 1, name: 'Safety Car' })).toHaveClass('font-marca');
    expect(screen.getByText('Assistência rodoviária conectada')).toHaveClass('uppercase');
    expect(screen.getByRole('img', { name: 'Safety Car' })).toHaveAttribute(
      'src',
      '/logo-icone.png',
    );
    expect(screen.getByRole('button', { name: 'Entrar' })).toHaveClass('rounded-full', 'bg-limao');
    expect(screen.getByRole('contentinfo')).toHaveTextContent(
      'Em urgência: 192 (SAMU) e 193 (Bombeiros)',
    );
    expect(screen.getByRole('link', { name: '192 (SAMU)' })).toHaveAttribute('href', 'tel:192');
  });

  test('ENTRAR leva ao Keycloak com destino "/"', async () => {
    const sessao = sessaoFalsa();
    abrir(sessao);
    await userEvent.click(screen.getByRole('button', { name: 'Entrar' }));
    expect(sessao.entrar).toHaveBeenCalledWith('/');
    expect(screen.getByRole('button', { name: 'Entrar' })).toBeDisabled();
  });

  test('ENTRAR leva o caminho de volta deixado pela rota protegida', async () => {
    const sessao = sessaoFalsa();
    abrir(sessao, { destino: '/central' });
    await userEvent.click(screen.getByRole('button', { name: 'Entrar' }));
    expect(sessao.entrar).toHaveBeenCalledWith('/central');
  });

  test('destino externo é ignorado (só caminho interno)', async () => {
    const sessao = sessaoFalsa();
    abrir(sessao, { destino: '//exemplo.invalid/roubo' });
    await userEvent.click(screen.getByRole('button', { name: 'Entrar' }));
    expect(sessao.entrar).toHaveBeenCalledWith('/');
  });

  test('se o Keycloak não responde, avisa e reabilita o botão', async () => {
    const sessao = sessaoFalsa({ entrar: vi.fn(() => Promise.reject(new Error('rede'))) });
    abrir(sessao);
    await userEvent.click(screen.getByRole('button', { name: 'Entrar' }));
    expect(await screen.findByRole('alert')).toHaveTextContent(
      'Não foi possível entrar. Tente novamente.',
    );
    expect(screen.getByRole('button', { name: 'Entrar' })).toBeEnabled();
  });

  test('cadastro desligado: "Criar conta, em breve", sem link nem botão', () => {
    abrir();
    expect(screen.getByText('Criar conta, em breve')).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: /criar conta/i })).not.toBeInTheDocument();
    expect(screen.queryByRole('link', { name: /criar conta/i })).not.toBeInTheDocument();
  });

  test('cadastro ligado: "Criar conta" branco sublinhado leva ao cadastro', async () => {
    const sessao = sessaoFalsa({ cadastroHabilitado: true });
    abrir(sessao);
    const criar = screen.getByRole('button', { name: 'Criar conta' });
    expect(criar).toHaveClass('text-branco', 'underline');
    await userEvent.click(criar);
    expect(sessao.criarConta).toHaveBeenCalledOnce();
  });

  test('quem já entrou vai direto para o próprio início', () => {
    abrir(sessaoFalsa({ acesso: { tipo: 'liberado', perfil: 'central' } }));
    expect(screen.getByText('área da central')).toBeInTheDocument();
  });

  test.each([{ tipo: 'pendente', perfil: 'tomador' }, { tipo: 'restrito' }] as const)(
    'conta $tipo vai para Acesso restrito',
    (acesso) => {
      abrir(sessaoFalsa({ acesso }));
      expect(screen.getByText('tela de acesso restrito')).toBeInTheDocument();
    },
  );

  test('sem falhas de acessibilidade (com e sem cadastro)', async () => {
    const { container, unmount } = abrir();
    expect(await axe(container)).toHaveNoViolations();
    unmount();
    const outro = abrir(sessaoFalsa({ cadastroHabilitado: true }));
    expect(await axe(outro.container)).toHaveNoViolations();
  });
});
