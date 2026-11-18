import type { ReactNode } from 'react';
import { classes } from './classes.ts';

interface Props {
  variante?: 'info' | 'atencao' | 'erro';
  titulo?: string;
  children: ReactNode;
  /**
   * Use só quando o aviso aparece em reação a uma ação (ex.: erro ao enviar):
   * aplica role="alert" e o leitor de tela anuncia na hora.
   */
  reacaoAAcao?: boolean;
  className?: string;
}

const estilosVariante = {
  info: 'bg-aviso-info-fundo text-aviso-info-texto',
  atencao: 'bg-aviso-atencao-fundo text-aviso-atencao-texto',
  erro: 'bg-aviso-erro-fundo text-aviso-erro-texto',
} as const;

export function CartaoAviso({
  variante = 'info',
  titulo,
  children,
  reacaoAAcao = false,
  className,
}: Props) {
  return (
    <div
      role={reacaoAAcao ? 'alert' : undefined}
      className={classes(
        'rounded-xl border-l-4 border-current p-4',
        estilosVariante[variante],
        className,
      )}
    >
      {titulo && <p className="mb-1 font-bold">{titulo}</p>}
      <div className="text-sm">{children}</div>
    </div>
  );
}
