import { screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { Route, Routes } from 'react-router';
import { describe, expect, test, vi } from 'vitest';
import { axe } from 'vitest-axe';
import type { Acesso } from '../autenticacao/tipos.ts';
import { renderizar, sessaoFalsa } from '../testes/sessao.tsx';
import { Entrando } from './Entrando.tsx';

function abrir(sessao = sessaoFalsa()) {
  return renderizar(
    <Routes>
      <Route path="entrando" element={<Entrando />} />
      <Route path="central" element={<p>área da central</p>} />
    </Routes>,
    { sessao, caminho: '/entrando' },
  );
}

const pendente = () => new Promise<string>(() => undefined);

describe('Entrando…', () => {
  test('mostra o anel, a marca e o estado em role="status"', async () => {
    const { container } = abrir(sessaoFalsa({ concluirEntrada: vi.fn(pendente) }));
    expect(screen.getByRole('status')).toHaveTextContent('Entrando…');
    expect(screen.getByRole('status')).toHaveClass('text-limao', 'font-semibold');
    expect(screen.getByText('Confirmando sua identidade e carregando seu perfil.')).toHaveClass(
      'text-texto-claro',
    );
    expect(screen.getByRole('heading', { level: 1, name: 'Safety Car' })).toBeInTheDocument();
    expect(screen.getByTestId('arco-carregando')).toHaveClass('animate-spin', 'border-t-limao');
    expect(await axe(container)).toHaveNoViolations();
  });

  test('conclui uma vez só e segue para o destino quando o perfil carrega', async () => {
    const sessao = sessaoFalsa({
      concluirEntrada: vi.fn(() => Promise.resolve('/central')),
      acesso: { tipo: 'liberado', perfil: 'central' },
    });
    abrir(sessao);
    expect(await screen.findByText('área da central')).toBeInTheDocument();
    expect(sessao.concluirEntrada).toHaveBeenCalledOnce();
  });

  test('espera o perfil: com acesso "verificando" continua em Entrando…', async () => {
    const acesso: Acesso = { tipo: 'verificando' };
    const sessao = sessaoFalsa({
      concluirEntrada: vi.fn(() => Promise.resolve('/central')),
      acesso,
    });
    abrir(sessao);
    await Promise.resolve();
    expect(screen.getByRole('status')).toHaveTextContent('Entrando…');
    expect(screen.queryByText('área da central')).not.toBeInTheDocument();
  });

  test('falha no retorno: mensagem e "Tentar de novo" volta ao Keycloak', async () => {
    const sessao = sessaoFalsa({
      concluirEntrada: vi.fn(() => Promise.reject(new Error('state inválido'))),
    });
    const { container } = abrir(sessao);
    expect(await screen.findByRole('alert')).toHaveTextContent(
      'Não foi possível entrar. Tente novamente.',
    );
    expect(screen.queryByTestId('arco-carregando')).not.toBeInTheDocument();
    await userEvent.click(screen.getByRole('button', { name: 'Tentar de novo' }));
    expect(sessao.entrar).toHaveBeenCalledWith('/');
    expect(await axe(container)).toHaveNoViolations();
  });

  test('API indisponível depois do retorno também mostra o erro', async () => {
    abrir(
      sessaoFalsa({
        concluirEntrada: vi.fn(() => Promise.resolve('/central')),
        acesso: { tipo: 'indisponivel' },
      }),
    );
    expect(await screen.findByRole('alert')).toBeInTheDocument();
  });
});
