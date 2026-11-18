import { useId, useState, type ChangeEvent, type ComponentPropsWithRef } from 'react';
import { classes, descricaoCampo } from './classes.ts';

const DIGITOS = 6;

type Props = Omit<
  ComponentPropsWithRef<'input'>,
  'type' | 'inputMode' | 'autoComplete' | 'maxLength' | 'pattern' | 'value' | 'defaultValue'
> & {
  rotulo: string;
  dica?: string;
  erro?: string;
  /** Valor controlado (só dígitos). Sem ele, o campo guarda o próprio estado. */
  value?: string;
  defaultValue?: string;
};

/**
 * Código de 6 dígitos (TOTP, verificação de e-mail ou celular).
 * Um único <input> desenhado como 6 caixas: colar e o preenchimento automático
 * funcionam, e o leitor de tela ouve um campo só.
 */
export function CampoCodigo({
  rotulo,
  dica,
  erro,
  id,
  className,
  value,
  defaultValue = '',
  onChange,
  ...props
}: Props) {
  const idGerado = useId();
  const idCampo = id ?? idGerado;
  const { idDica, idErro, describedBy } = descricaoCampo(idCampo, Boolean(dica), Boolean(erro));
  const [interno, setInterno] = useState(() => apenasDigitos(defaultValue));
  const valor = value ?? interno;

  function aoMudar(evento: ChangeEvent<HTMLInputElement>) {
    // Mantém só dígitos antes de repassar, também para quem registra o campo por ref.
    evento.target.value = apenasDigitos(evento.target.value);
    setInterno(evento.target.value);
    onChange?.(evento);
  }

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
      <div className="group relative w-fit">
        <div className="flex gap-2" aria-hidden="true">
          {Array.from({ length: DIGITOS }, (_, i) => (
            <span
              key={i}
              className={classes(
                'flex h-12 w-11 items-center justify-center rounded-lg bg-branco text-xl font-bold text-texto',
                erro ? 'border-2 border-erro' : 'border border-borda-campo',
                i === Math.min(valor.length, DIGITOS - 1) &&
                  'group-focus-within:border-2 group-focus-within:border-marinho',
              )}
            >
              {valor[i] ?? ''}
            </span>
          ))}
        </div>
        <input
          id={idCampo}
          type="text"
          inputMode="numeric"
          autoComplete="one-time-code"
          pattern="[0-9]{6}"
          // Sem maxLength: o navegador cortaria o texto colado antes da limpeza
          // ("123 456" viraria "12345"). O limite de 6 dígitos fica no aoMudar.
          spellCheck={false}
          value={valor}
          onChange={aoMudar}
          aria-invalid={erro ? true : undefined}
          aria-describedby={describedBy}
          className="absolute inset-0 h-full w-full rounded-lg bg-transparent text-transparent caret-transparent selection:bg-transparent"
          {...props}
        />
      </div>
      {erro && (
        <p id={idErro} className="text-sm font-semibold text-erro">
          {erro}
        </p>
      )}
    </div>
  );
}

function apenasDigitos(texto: string): string {
  return texto.replace(/\D/g, '').slice(0, DIGITOS);
}
