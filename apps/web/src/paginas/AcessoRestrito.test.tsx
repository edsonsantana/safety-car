import { screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { Route, Routes } from 'react-router';
import { describe, expect, test } from 'vitest';
import { axe } from 'vitest-axe';
import type { Acesso } from '../autenticacao/tipos.ts';
import { renderizar, sessaoFalsa } from '../testes/sessao.tsx';
import { AcessoRestrito } from './AcessoRestrito.tsx';

function abrir(acesso: Acesso) {
  const sessao = sessaoFalsa({ acesso });
  const resultado = renderizar(
    <Routes>
      <Route path="acesso-restrito" element={<AcessoRestrito />} />
      <Route index element={<p>tela de entrada</p>} />
    </Routes>,
    { sessao, caminho: '/acesso-restrito' },
  );
  return { ...resultado, sessao };
}

const TEXTO_ATIVO =
  'Sua conta está ativa, mas o seu perfil não tem acesso a esta área do Safety Car. Nada foi alterado na sua conta.';
const TEXTO_NAO_LIBERADO =
  'Sua conta ainda não foi liberada para esta área. Nada foi alterado na sua conta.';

describe('Acesso restrito', () => {
  test('perfil ativo: texto de conta ativa e "Ir para o meu início" no próprio início', async () => {
    const { container } = abrir({ tipo: 'liberado', perfil: 'parceiro' });
    expect(
      screen.getByRole('heading', { level: 1, name: 'Esta área é restrita' }),
    ).toBeInTheDocument();
    expect(screen.getByText(TEXTO_ATIVO)).toBeInTheDocument();
    expect(
      screen.getByText(
        'Se você acredita que deveria ter acesso, fale com a Central. A liberação é feita por um administrador e fica registrada.',
      ),
    ).toHaveClass('border-l-4', 'border-limao', 'bg-branco');
    const inicio = screen.getByRole('link', { name: 'Ir para o meu início' });
    expect(inicio).toHaveAttribute('href', '/parceiro');
    expect(inicio).toHaveClass('rounded-full', 'bg-limao');
    expect(screen.getByRole('region', { name: 'Esta área é restrita' })).toHaveClass(
      'bg-fundo',
      'rounded-[20px]',
    );
    expect(await axe(container)).toHaveNoViolations();
  });

  test.each([
    ['pendente', { tipo: 'pendente', perfil: 'tomador' }],
    ['restrito (sem registro, suspenso etc.)', { tipo: 'restrito' }],
  ] as const)('%s: "ainda não foi liberada" e sem "Ir para o meu início"', async (_, acesso) => {
    const { container } = abrir(acesso);
    expect(screen.getByText(TEXTO_NAO_LIBERADO)).toBeInTheDocument();
    expect(screen.queryByText(/Sua conta está ativa/)).not.toBeInTheDocument();
    expect(screen.queryByRole('link', { name: 'Ir para o meu início' })).not.toBeInTheDocument();
    expect(await axe(container)).toHaveNoViolations();
  });

  test('não mostra "Falar com a Central" (canal ainda não definido)', () => {
    abrir({ tipo: 'liberado', perfil: 'tomador' });
    expect(screen.queryByRole('button', { name: /falar com a central/i })).not.toBeInTheDocument();
    expect(screen.queryByRole('link', { name: /falar com a central/i })).not.toBeInTheDocument();
  });

  test('"Sair" (verde-limão, fora do cartão) encerra a sessão', async () => {
    const { sessao } = abrir({ tipo: 'restrito' });
    const sair = screen.getByRole('button', { name: 'Sair' });
    expect(sair).toHaveClass('text-limao');
    expect(screen.getByRole('region', { name: 'Esta área é restrita' })).not.toContainElement(sair);
    await userEvent.click(sair);
    expect(sessao.sair).toHaveBeenCalledOnce();
  });

  test('sem sessão volta para a entrada', () => {
    abrir({ tipo: 'anonimo' });
    expect(screen.getByText('tela de entrada')).toBeInTheDocument();
  });

  test('carregando mostra Entrando…; API fora mostra o erro com Tentar de novo', async () => {
    const { unmount } = abrir({ tipo: 'verificando' });
    expect(screen.getByRole('status')).toHaveTextContent('Entrando…');
    unmount();
    const { sessao } = abrir({ tipo: 'indisponivel' });
    await userEvent.click(screen.getByRole('button', { name: 'Tentar de novo' }));
    expect(sessao.recarregarPerfil).toHaveBeenCalledOnce();
  });
});
