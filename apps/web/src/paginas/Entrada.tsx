import { useState } from 'react';
import { Navigate, useLocation } from 'react-router';
import { useSessao } from '../autenticacao/contexto.ts';
import { destinoSeguro, INICIO_DO_PERFIL } from '../autenticacao/tipos.ts';
import { Botao } from '../componentes/Botao.tsx';
import { LayoutEscuro, LOGO, NomeMarca } from '../layouts/LayoutEscuro.tsx';

/** Tela de entrada do app ("/"): ENTRAR leva ao Keycloak; quem já entrou vai ao seu início. */
export function Entrada() {
  const { acesso, entrar, criarConta, cadastroHabilitado } = useSessao();
  const local = useLocation();
  const [indo, setIndo] = useState(false);
  const [falhou, setFalhou] = useState(false);

  if (acesso.tipo === 'liberado') return <Navigate to={INICIO_DO_PERFIL[acesso.perfil]} replace />;
  if (acesso.tipo === 'pendente' || acesso.tipo === 'restrito') {
    return <Navigate to="/acesso-restrito" replace />;
  }

  // Caminho de volta deixado pela rota protegida (só caminho interno).
  const estado: unknown = local.state;
  const destino = destinoSeguro(
    typeof estado === 'object' && estado !== null && 'destino' in estado
      ? estado.destino
      : undefined,
  );

  function ir(acao: () => Promise<void>) {
    setIndo(true);
    setFalhou(false);
    // Se der certo, a página sai para o Keycloak; só volta aqui se falhar.
    acao().catch(() => {
      setIndo(false);
      setFalhou(true);
    });
  }

  return (
    <LayoutEscuro comCabecalho>
      <title>Safety Car</title>
      <p className="text-xs font-bold tracking-[0.2em] text-limao uppercase">
        Assistência rodoviária conectada
      </p>
      <NomeMarca como="h1" />
      <img src={LOGO} alt="" width={130} height={130} className="size-[130px]" />
      <div className="flex w-full flex-col items-center gap-4">
        <Botao
          className="w-full"
          disabled={indo}
          onClick={() => {
            ir(() => entrar(destino));
          }}
        >
          Entrar
        </Botao>
        {falhou && (
          <p role="alert" className="font-semibold text-limao">
            Não foi possível entrar. Tente novamente.
          </p>
        )}
        {cadastroHabilitado ? (
          <button
            type="button"
            disabled={indo}
            onClick={() => {
              ir(criarConta);
            }}
            className="min-h-11 rounded-lg px-2 text-branco underline underline-offset-4"
          >
            Criar conta
          </button>
        ) : (
          <p className="text-texto-claro">Criar conta, em breve</p>
        )}
      </div>
    </LayoutEscuro>
  );
}
