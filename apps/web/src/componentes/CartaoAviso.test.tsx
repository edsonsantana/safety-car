import { render, screen } from '@testing-library/react';
import { describe, expect, test } from 'vitest';
import { axe } from 'vitest-axe';
import { CartaoAviso } from './CartaoAviso.tsx';

describe('CartaoAviso', () => {
  test('mostra título e conteúdo', () => {
    render(<CartaoAviso titulo="Atenção">Confira o e-mail.</CartaoAviso>);
    expect(screen.getByText('Atenção')).toBeInTheDocument();
    expect(screen.getByText('Confira o e-mail.')).toBeInTheDocument();
  });

  test('sem reação a uma ação, não usa role="alert"', () => {
    render(<CartaoAviso variante="atencao">Aviso fixo</CartaoAviso>);
    expect(screen.queryByRole('alert')).not.toBeInTheDocument();
  });

  test('em reação a uma ação, usa role="alert"', () => {
    render(
      <CartaoAviso variante="erro" reacaoAAcao>
        Não foi possível enviar.
      </CartaoAviso>,
    );
    expect(screen.getByRole('alert')).toHaveTextContent('Não foi possível enviar.');
  });

  test.each(['info', 'atencao', 'erro'] as const)('variante %s usa as cores próprias', (v) => {
    render(<CartaoAviso variante={v}>Texto</CartaoAviso>);
    expect(screen.getByText('Texto').parentElement).toHaveClass(`bg-aviso-${v}-fundo`);
  });

  test('sem falhas de acessibilidade', async () => {
    const { container } = render(
      <>
        <CartaoAviso titulo="Info">Texto</CartaoAviso>
        <CartaoAviso variante="atencao">Texto</CartaoAviso>
        <CartaoAviso variante="erro" reacaoAAcao>
          Texto
        </CartaoAviso>
      </>,
    );
    expect(await axe(container)).toHaveNoViolations();
  });
});
