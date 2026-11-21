import type { ComponentPropsWithRef } from 'react';
import { classes, classesBotao } from './classes.ts';

type Props = ComponentPropsWithRef<'button'> & {
  /**
   * `principal`: pílula verde-limão com texto azul-marinho em caixa-alta (só sobre fundo
   * escuro ou azul-marinho: o limão nunca vai sobre fundo claro).
   * `secundario`: contorno azul-marinho.
   */
  variante?: 'principal' | 'secundario';
};

export function Botao({ variante = 'principal', type = 'button', className, ...props }: Props) {
  return <button type={type} className={classes(classesBotao(variante), className)} {...props} />;
}
