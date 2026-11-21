/** Junta classes CSS, ignorando valores vazios. */
export function classes(...lista: (string | false | null | undefined)[]): string {
  return lista.filter(Boolean).join(' ');
}

/** Estilo de botão, também usado em links com cara de botão (ex.: "Ir para o meu início"). */
export function classesBotao(variante: 'principal' | 'secundario'): string {
  const estilos = {
    principal:
      'rounded-full bg-limao text-marinho border-2 border-limao uppercase tracking-widest hover:brightness-95',
    secundario: 'rounded-xl bg-branco text-marinho border-2 border-marinho hover:bg-fundo',
  } as const;
  return classes(
    'inline-flex min-h-11 min-w-11 items-center justify-center gap-2 px-5 py-2 font-bold transition',
    'disabled:cursor-not-allowed disabled:opacity-60',
    estilos[variante],
  );
}

/** Ids da dica e do erro de um campo, e o aria-describedby resultante. */
export function descricaoCampo(base: string, temDica: boolean, temErro: boolean) {
  const idDica = `${base}-dica`;
  const idErro = `${base}-erro`;
  const describedBy = [temDica && idDica, temErro && idErro].filter(Boolean).join(' ');
  return { idDica, idErro, describedBy: describedBy || undefined };
}
