import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { describe, expect, test, vi } from 'vitest';
import { axe } from 'vitest-axe';
import { Botao } from './Botao.tsx';

describe('Botao', () => {
  test('é um botão do tipo "button" por padrão e responde ao clique', async () => {
    const aoClicar = vi.fn();
    render(<Botao onClick={aoClicar}>Continuar</Botao>);
    const botao = screen.getByRole('button', { name: 'Continuar' });
    expect(botao).toHaveAttribute('type', 'button');
    await userEvent.click(botao);
    expect(aoClicar).toHaveBeenCalledOnce();
  });

  test('principal usa verde-limão com texto azul-marinho e altura mínima de 44 px', () => {
    render(<Botao>Entrar</Botao>);
    expect(screen.getByRole('button')).toHaveClass('bg-limao', 'text-marinho', 'min-h-11');
  });

  test('secundário tem contorno azul-marinho', () => {
    render(<Botao variante="secundario">Voltar</Botao>);
    expect(screen.getByRole('button')).toHaveClass('border-marinho', 'bg-branco');
  });

  test('desabilitado não dispara o clique', async () => {
    const aoClicar = vi.fn();
    render(
      <Botao disabled onClick={aoClicar}>
        Enviar
      </Botao>,
    );
    await userEvent.click(screen.getByRole('button'));
    expect(aoClicar).not.toHaveBeenCalled();
    expect(screen.getByRole('button')).toBeDisabled();
  });

  test('recebe foco pelo teclado', async () => {
    render(<Botao>Entrar</Botao>);
    await userEvent.tab();
    expect(screen.getByRole('button')).toHaveFocus();
  });

  test('sem falhas de acessibilidade', async () => {
    const { container } = render(
      <>
        <Botao>Principal</Botao>
        <Botao variante="secundario">Secundário</Botao>
      </>,
    );
    expect(await axe(container)).toHaveNoViolations();
  });
});
