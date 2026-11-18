import { classes } from './classes.ts';

/** Mesmos valores do banco onde se aplicam (ex.: parceiro_documento.status). */
export type StatusSelo = 'aprovado' | 'em_analise' | 'pendente' | 'vencido';

const selos: Record<StatusSelo, { texto: string; estilo: string }> = {
  aprovado: { texto: 'Aprovado', estilo: 'bg-selo-aprovado-fundo text-selo-aprovado-texto' },
  em_analise: {
    texto: 'Em análise',
    estilo: 'bg-selo-em-analise-fundo text-selo-em-analise-texto',
  },
  pendente: { texto: 'Pendente', estilo: 'bg-selo-pendente-fundo text-selo-pendente-texto' },
  vencido: { texto: 'Vencido', estilo: 'bg-selo-vencido-fundo text-selo-vencido-texto' },
};

interface Props {
  status: StatusSelo;
  className?: string;
}

/** A cor nunca é o único sinal: o selo sempre traz o status escrito. */
export function SeloStatus({ status, className }: Props) {
  const { texto, estilo } = selos[status];
  return (
    <span
      className={classes(
        'inline-flex items-center rounded-full px-3 py-1 text-xs font-bold',
        estilo,
        className,
      )}
    >
      {texto}
    </span>
  );
}
