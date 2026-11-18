import { useId, type ComponentPropsWithRef } from 'react';
import { classes, descricaoCampo } from './classes.ts';

type Props = ComponentPropsWithRef<'input'> & {
  /** Rótulo sempre visível. */
  rotulo: string;
  dica?: string;
  /** Mensagem de erro: marca o campo com aria-invalid e é anunciada pelo aria-describedby. */
  erro?: string;
};

export function CampoTexto({ rotulo, dica, erro, id, className, type = 'text', ...props }: Props) {
  const idGerado = useId();
  const idCampo = id ?? idGerado;
  const { idDica, idErro, describedBy } = descricaoCampo(idCampo, Boolean(dica), Boolean(erro));

  return (
    <div className={classes('flex flex-col gap-1', className)}>
      <label htmlFor={idCampo} className="font-semibold text-texto">
        {rotulo}
      </label>
      {dica && (
        <p id={idDica} className="text-sm text-texto-sec">
          {dica}
        </p>
      )}
      <input
        id={idCampo}
        type={type}
        aria-invalid={erro ? true : undefined}
        aria-describedby={describedBy}
        className={classes(
          'min-h-11 rounded-lg border bg-branco px-3 text-texto',
          erro ? 'border-2 border-erro' : 'border-borda-campo',
        )}
        {...props}
      />
      {erro && (
        <p id={idErro} className="text-sm font-semibold text-erro">
          {erro}
        </p>
      )}
    </div>
  );
}
