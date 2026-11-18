import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { createRef, useState } from 'react';
import { describe, expect, test, vi } from 'vitest';
import { axe } from 'vitest-axe';
import { CampoCodigo } from './CampoCodigo.tsx';

describe('CampoCodigo', () => {
  test('é um único campo, com teclado numérico e preenchimento automático do código', () => {
    render(<CampoCodigo rotulo="Código do autenticador" />);
    const campos = screen.getAllByRole('textbox');
    expect(campos).toHaveLength(1);
    const campo = campos[0];
    expect(campo).toHaveAccessibleName('Código do autenticador');
    expect(campo).toHaveAttribute('inputmode', 'numeric');
    expect(campo).toHaveAttribute('autocomplete', 'one-time-code');
  });

  test('desenha 6 caixas com os dígitos digitados', async () => {
    const { container } = render(<CampoCodigo rotulo="Código" />);
    await userEvent.type(screen.getByRole('textbox'), '123');
    const caixas = container.querySelectorAll('[aria-hidden="true"] > span');
    expect(caixas).toHaveLength(6);
    expect([...caixas].map((c) => c.textContent)).toEqual(['1', '2', '3', '', '', '']);
  });

  test('colar o código mantém só os dígitos, até 6', async () => {
    const aoMudar = vi.fn();
    render(<CampoCodigo rotulo="Código" onChange={aoMudar} />);
    const campo = screen.getByRole('textbox');
    await userEvent.click(campo);
    await userEvent.paste('12 34-56');
    expect(campo).toHaveValue('123456');
    expect(aoMudar).toHaveBeenCalled();
  });

  test('não passa de 6 dígitos', async () => {
    render(<CampoCodigo rotulo="Código" />);
    const campo = screen.getByRole('textbox');
    await userEvent.type(campo, '12345678');
    expect(campo).toHaveValue('123456');
  });

  test('ignora letras', async () => {
    render(<CampoCodigo rotulo="Código" />);
    const campo = screen.getByRole('textbox');
    await userEvent.type(campo, '1a2b');
    expect(campo).toHaveValue('12');
  });

  test('funciona controlado', async () => {
    function Controlado() {
      const [codigo, setCodigo] = useState('');
      return (
        <>
          <CampoCodigo
            rotulo="Código"
            value={codigo}
            onChange={(e) => {
              setCodigo(e.target.value);
            }}
          />
          <output>{codigo}</output>
        </>
      );
    }
    render(<Controlado />);
    await userEvent.type(screen.getByRole('textbox'), '98x7');
    expect(screen.getByRole('status')).toHaveTextContent('987');
  });

  test('o erro marca aria-invalid e é anunciado pela descrição', () => {
    render(<CampoCodigo rotulo="Código" erro="Código incorreto" />);
    const campo = screen.getByRole('textbox');
    expect(campo).toBeInvalid();
    expect(campo).toHaveAccessibleDescription('Código incorreto');
  });

  test('aceita ref', () => {
    const ref = createRef<HTMLInputElement>();
    render(<CampoCodigo rotulo="Código" ref={ref} />);
    expect(ref.current).toBe(screen.getByRole('textbox'));
  });

  test('sem falhas de acessibilidade', async () => {
    const { container } = render(
      <CampoCodigo rotulo="Código" dica="6 dígitos do aplicativo" erro="Código incorreto" />,
    );
    expect(await axe(container)).toHaveNoViolations();
  });
});
