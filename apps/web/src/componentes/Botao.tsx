import type { ComponentPropsWithRef } from 'react';
import { classes } from './classes.ts';

type Props = ComponentPropsWithRef<'button'> & {
  /** `principal`: verde-limão com texto azul-marinho. `secundario`: contorno azul-marinho. */
  variante?: 'principal' | 'secundario';
};

const estilosVariante = {
  principal: 'bg-limao text-marinho border-2 border-limao hover:brightness-95',
  secundario: 'bg-branco text-marinho border-2 border-marinho hover:bg-fundo',
} as const;

export function Botao({ variante = 'principal', type = 'button', className, ...props }: Props) {
  return (
    <button
      type={type}
      className={classes(
        'inline-flex min-h-11 min-w-11 items-center justify-center gap-2 rounded-xl px-5 py-2 font-bold transition',
        'disabled:cursor-not-allowed disabled:opacity-60',
        estilosVariante[variante],
        className,
      )}
      {...props}
    />
  );
}
