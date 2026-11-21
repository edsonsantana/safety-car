import { screen } from '@testing-library/react';
import { Route, Routes, useLocation } from 'react-router';
import { describe, expect, test } from 'vitest';
import { renderizar, sessaoFalsa } from '../testes/sessao.tsx';
import { RotaProtegida } from './RotaProtegida.tsx';
import type { Acesso } from './tipos.ts';

function EntradaFalsa() {
  const local = useLocation();
  return <p>entrada; destino: {JSON.stringify(local.state)}</p>;
}

function abrir(acesso: Acesso, caminho = '/central') {
  return renderizar(
    <Routes>
      <Route index element={<EntradaFalsa />} />
      <Route element={<RotaProtegida perfis={['central']} />}>
        <Route path="central" element={<p>conteúdo da central</p>} />
      </Route>
    </Routes>,
    { sessao: sessaoFalsa({ acesso }), caminho },
  );
}

describe('RotaProtegida', () => {
  test('perfil permitido e ativo: mostra a área', () => {
    abrir({ tipo: 'liberado', perfil: 'central' });
    expect(screen.getByText('conteúdo da central')).toBeInTheDocument();
  });

  test('sem sessão: vai para a entrada guardando o caminho de volta', () => {
    abrir({ tipo: 'anonimo' }, '/central');
    expect(screen.getByText('entrada; destino: {"destino":"/central"}')).toBeInTheDocument();
    expect(screen.queryByText('conteúdo da central')).not.toBeInTheDocument();
  });

  test('verificando: mostra Entrando…, sem o conteúdo', () => {
    abrir({ tipo: 'verificando' });
    expect(screen.getByRole('status')).toHaveTextContent('Entrando…');
    expect(screen.queryByText('conteúdo da central')).not.toBeInTheDocument();
  });

  test.each(['tomador', 'parceiro'] as const)(
    'perfil %s ativo na área da Central: Acesso restrito com o próprio início',
    (perfil) => {
      abrir({ tipo: 'liberado', perfil });
      expect(screen.getByRole('heading', { name: 'Esta área é restrita' })).toBeInTheDocument();
      expect(screen.getByRole('link', { name: 'Ir para o meu início' })).toHaveAttribute(
        'href',
        `/${perfil}`,
      );
      expect(screen.queryByText('conteúdo da central')).not.toBeInTheDocument();
    },
  );

  test.each([{ tipo: 'pendente', perfil: 'central' }, { tipo: 'restrito' }] as const)(
    '$tipo (mesmo com perfil central): Acesso restrito sem início',
    (acesso) => {
      abrir(acesso);
      expect(screen.getByRole('heading', { name: 'Esta área é restrita' })).toBeInTheDocument();
      expect(screen.queryByRole('link', { name: 'Ir para o meu início' })).not.toBeInTheDocument();
      expect(screen.queryByText('conteúdo da central')).not.toBeInTheDocument();
    },
  );

  test('API indisponível: erro com Tentar de novo, sem o conteúdo', () => {
    abrir({ tipo: 'indisponivel' });
    expect(screen.getByRole('alert')).toHaveTextContent('Não foi possível entrar.');
    expect(screen.getByRole('button', { name: 'Tentar de novo' })).toBeInTheDocument();
    expect(screen.queryByText('conteúdo da central')).not.toBeInTheDocument();
  });
});
