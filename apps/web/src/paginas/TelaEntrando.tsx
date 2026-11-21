import { Botao } from '../componentes/Botao.tsx';
import { LayoutEscuro, LOGO, NomeMarca } from '../layouts/LayoutEscuro.tsx';

interface Props {
  /** Mostra "Não foi possível entrar" com o botão "Tentar de novo". */
  erro?: boolean;
  aoTentarDeNovo?: () => void;
}

/**
 * "Entrando…": logo dentro de um anel com um arco verde-limão girando (o giro para com
 * prefers-reduced-motion). Usada no retorno do login e enquanto o perfil carrega.
 */
export function TelaEntrando({ erro = false, aoTentarDeNovo }: Props) {
  return (
    <LayoutEscuro>
      <title>{erro ? 'Não foi possível entrar · Safety Car' : 'Entrando · Safety Car'}</title>
      <div className="relative flex size-[170px] items-center justify-center">
        <span
          aria-hidden="true"
          className="absolute inset-0 rounded-full border-[5px] border-anel"
        />
        {!erro && (
          <span
            aria-hidden="true"
            data-testid="arco-carregando"
            className="absolute inset-0 animate-spin rounded-full border-[5px] border-transparent border-t-limao"
          />
        )}
        <img src={LOGO} alt="" width={130} height={130} className="size-[130px]" />
      </div>
      <NomeMarca como="h1" />
      {erro ? (
        <>
          <p role="alert" className="font-semibold text-limao">
            Não foi possível entrar. Tente novamente.
          </p>
          {aoTentarDeNovo && (
            <Botao className="w-full" onClick={aoTentarDeNovo}>
              Tentar de novo
            </Botao>
          )}
        </>
      ) : (
        <div className="flex flex-col gap-2">
          <p role="status" className="text-lg font-semibold text-limao">
            Entrando…
          </p>
          <p className="text-texto-claro">Confirmando sua identidade e carregando seu perfil.</p>
        </div>
      )}
    </LayoutEscuro>
  );
}
