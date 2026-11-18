import { render, screen } from '@testing-library/react';
import { describe, expect, test } from 'vitest';
import { axe } from 'vitest-axe';
import { IndicadorEtapas } from './IndicadorEtapas.tsx';

const etapas = ['Dados', 'Celular', 'Senha', '2FA'];

describe('IndicadorEtapas', () => {
  test('mostra "Etapa N de M"', () => {
    render(<IndicadorEtapas etapas={etapas} atual={2} />);
    expect(screen.getByText('Etapa 2 de 4')).toBeInTheDocument();
  });

  test('lista ordenada com aria-current="step" só na etapa atual', () => {
    render(<IndicadorEtapas etapas={etapas} atual={2} />);
    const itens = screen.getAllByRole('listitem');
    expect(itens).toHaveLength(4);
    expect(itens.map((i) => i.getAttribute('aria-current'))).toEqual([null, 'step', null, null]);
    expect(screen.getByRole('list').tagName).toBe('OL');
  });

  test('etapas concluídas são anunciadas como concluídas', () => {
    render(<IndicadorEtapas etapas={etapas} atual={3} />);
    expect(screen.getAllByText('(concluída)')).toHaveLength(2);
  });

  test('sem falhas de acessibilidade', async () => {
    const { container } = render(<IndicadorEtapas etapas={etapas} atual={2} />);
    expect(await axe(container)).toHaveNoViolations();
  });
});
