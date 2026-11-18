import { classes } from './classes.ts';

interface Props {
  /** Nomes das etapas, na ordem. */
  etapas: readonly string[];
  /** Etapa atual, a partir de 1. */
  atual: number;
  className?: string;
}

export function IndicadorEtapas({ etapas, atual, className }: Props) {
  return (
    <div className={classes('flex flex-col gap-2', className)}>
      <p className="text-sm font-semibold text-texto-sec">
        Etapa {atual} de {etapas.length}
      </p>
      <ol className="flex gap-2">
        {etapas.map((nome, i) => {
          const numero = i + 1;
          const situacao = numero < atual ? 'concluida' : numero === atual ? 'atual' : 'futura';
          return (
            <li
              key={nome}
              aria-current={situacao === 'atual' ? 'step' : undefined}
              className="flex flex-1 flex-col items-center gap-1 text-center text-xs"
            >
              <span
                aria-hidden="true"
                className={classes(
                  'flex size-8 items-center justify-center rounded-full border-2 font-bold',
                  situacao === 'concluida' && 'border-marinho bg-marinho text-branco',
                  situacao === 'atual' && 'border-marinho bg-limao text-marinho',
                  situacao === 'futura' && 'border-borda-campo bg-branco text-texto-sec',
                )}
              >
                {situacao === 'concluida' ? '✓' : numero}
              </span>
              <span className={situacao === 'futura' ? 'text-texto-sec' : 'text-texto'}>
                {nome}
                {situacao === 'concluida' && <span className="sr-only"> (concluída)</span>}
              </span>
            </li>
          );
        })}
      </ol>
    </div>
  );
}
