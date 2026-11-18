import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { createRef } from 'react';
import { describe, expect, test } from 'vitest';
import { axe } from 'vitest-axe';
import { CampoTexto } from './CampoTexto.tsx';

describe('CampoTexto', () => {
  test('o rótulo nomeia o campo', async () => {
    render(<CampoTexto rotulo="E-mail" type="email" />);
    const campo = screen.getByRole('textbox', { name: 'E-mail' });
    await userEvent.type(campo, 'a@b.com');
    expect(campo).toHaveValue('a@b.com');
  });

  test('a dica descreve o campo', () => {
    render(<CampoTexto rotulo="Nome" dica="Como no documento" />);
    expect(screen.getByRole('textbox')).toHaveAccessibleDescription('Como no documento');
  });

  test('o erro marca aria-invalid e é anunciado pela descrição', () => {
    render(<CampoTexto rotulo="Nome" dica="Como no documento" erro="Informe o nome" />);
    const campo = screen.getByRole('textbox');
    expect(campo).toBeInvalid();
    expect(campo).toHaveAccessibleDescription('Como no documento Informe o nome');
  });

  test('sem erro, não marca aria-invalid nem descrição', () => {
    render(<CampoTexto rotulo="Nome" />);
    const campo = screen.getByRole('textbox');
    expect(campo).not.toHaveAttribute('aria-invalid');
    expect(campo).not.toHaveAttribute('aria-describedby');
  });

  test('aceita ref (para o React Hook Form)', () => {
    const ref = createRef<HTMLInputElement>();
    render(<CampoTexto rotulo="Nome" ref={ref} />);
    expect(ref.current).toBe(screen.getByRole('textbox'));
  });

  test('sem falhas de acessibilidade, com e sem erro', async () => {
    const { container } = render(
      <>
        <CampoTexto rotulo="Nome" dica="Como no documento" />
        <CampoTexto rotulo="E-mail" erro="E-mail inválido" />
      </>,
    );
    expect(await axe(container)).toHaveNoViolations();
  });
});
