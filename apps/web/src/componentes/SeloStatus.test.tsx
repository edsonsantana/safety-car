import { render, screen } from '@testing-library/react';
import { describe, expect, test } from 'vitest';
import { axe } from 'vitest-axe';
import { SeloStatus, type StatusSelo } from './SeloStatus.tsx';

const casos: [StatusSelo, string][] = [
  ['aprovado', 'Aprovado'],
  ['em_analise', 'Em análise'],
  ['pendente', 'Pendente'],
  ['vencido', 'Vencido'],
];

describe('SeloStatus', () => {
  test.each(casos)('%s traz o texto "%s" (a cor nunca é o único sinal)', (status, texto) => {
    render(<SeloStatus status={status} />);
    expect(screen.getByText(texto)).toHaveClass(`bg-selo-${status.replace('_', '-')}-fundo`);
  });

  test('sem falhas de acessibilidade', async () => {
    const { container } = render(
      <>
        {casos.map(([status]) => (
          <SeloStatus key={status} status={status} />
        ))}
      </>,
    );
    expect(await axe(container)).toHaveNoViolations();
  });
});
