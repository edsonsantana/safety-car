/** Junta classes CSS, ignorando valores vazios. */
export function classes(...lista: (string | false | null | undefined)[]): string {
  return lista.filter(Boolean).join(' ');
}

/** Ids da dica e do erro de um campo, e o aria-describedby resultante. */
export function descricaoCampo(base: string, temDica: boolean, temErro: boolean) {
  const idDica = `${base}-dica`;
  const idErro = `${base}-erro`;
  const describedBy = [temDica && idDica, temErro && idErro].filter(Boolean).join(' ');
  return { idDica, idErro, describedBy: describedBy || undefined };
}
