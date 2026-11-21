import { Link, Navigate } from 'react-router';
import { useSessao } from '../autenticacao/contexto.ts';
import { INICIO_DO_PERFIL } from '../autenticacao/tipos.ts';
import { classesBotao } from '../componentes/classes.ts';
import { LayoutEscuro, LOGO, NomeMarca } from '../layouts/LayoutEscuro.tsx';
import { TelaEntrando } from './TelaEntrando.tsx';

const TEXTO_ATIVO =
  'Sua conta está ativa, mas o seu perfil não tem acesso a esta área do Safety Car. Nada foi alterado na sua conta.';
// Pendente e restrito (sem registro, suspenso etc.) recebem o mesmo texto: não revela qual.
const TEXTO_NAO_LIBERADO =
  'Sua conta ainda não foi liberada para esta área. Nada foi alterado na sua conta.';

/**
 * Conta válida no Keycloak, mas sem acesso à área pedida. "Ir para o meu início" só
 * aparece com perfil ativo. "Falar com a Central" fica de fora até haver canal definido.
 */
export function AcessoRestrito() {
  const { acesso, sair, recarregarPerfil } = useSessao();

  if (acesso.tipo === 'anonimo') return <Navigate to="/" replace />;
  if (acesso.tipo === 'verificando') return <TelaEntrando />;
  if (acesso.tipo === 'indisponivel') {
    return (
      <TelaEntrando
        erro
        aoTentarDeNovo={() => {
          void recarregarPerfil();
        }}
      />
    );
  }

  const inicio = acesso.tipo === 'liberado' ? INICIO_DO_PERFIL[acesso.perfil] : undefined;

  return (
    <LayoutEscuro>
      <title>Acesso restrito · Safety Car</title>
      <div className="flex flex-col items-center gap-4">
        <NomeMarca />
        <img src={LOGO} alt="" width={130} height={130} className="size-[130px]" />
      </div>

      <section
        aria-labelledby="titulo-acesso-restrito"
        className="flex w-full flex-col gap-4 rounded-[20px] bg-fundo p-6 text-left text-texto"
      >
        <span
          aria-hidden="true"
          className="inline-flex size-12 items-center justify-center rounded-xl bg-marinho text-limao"
        >
          <IconeCadeado />
        </span>
        <h1 id="titulo-acesso-restrito" className="text-2xl font-bold text-marinho">
          Esta área é restrita
        </h1>
        <p>{inicio ? TEXTO_ATIVO : TEXTO_NAO_LIBERADO}</p>
        <p className="rounded-lg border-l-4 border-limao bg-branco p-4">
          Se você acredita que deveria ter acesso, fale com a Central. A liberação é feita por um
          administrador e fica registrada.
        </p>
      </section>

      <div className="flex w-full flex-col items-center gap-2">
        {inicio && (
          <Link to={inicio} className={`${classesBotao('principal')} w-full`}>
            Ir para o meu início
          </Link>
        )}
        <button
          type="button"
          onClick={() => {
            void sair();
          }}
          className="min-h-11 min-w-11 rounded-lg px-4 font-semibold text-limao underline underline-offset-4"
        >
          Sair
        </button>
      </div>
    </LayoutEscuro>
  );
}

function IconeCadeado() {
  return (
    <svg
      width="24"
      height="24"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="2.25"
      strokeLinecap="round"
      strokeLinejoin="round"
      focusable="false"
    >
      <rect x="4" y="10.5" width="16" height="10.5" rx="2" />
      <path d="M8 10.5V7a4 4 0 0 1 8 0v3.5" />
    </svg>
  );
}
