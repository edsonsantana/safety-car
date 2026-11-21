import { type ReactNode, useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { consultarMe } from '../api/me.ts';
import { ContextoSessao } from './contexto.ts';
import { CAMINHO_RETORNO, type ServicoAutenticacao } from './oidc.ts';
import type { Acesso, Sessao } from './tipos.ts';

interface Props {
  servico: ServicoAutenticacao;
  cadastroHabilitado: boolean;
  children: ReactNode;
  /** Caminho atual na abertura (padrão: window.location.pathname). */
  caminhoInicial?: string;
}

/**
 * Guarda a sessão em memória e o acesso vindo do GET /me.
 * Na abertura (inclusive depois de um F5) tenta a renovação silenciosa; em /entrando,
 * quem conclui é a tela de retorno.
 */
export function ProvedorSessao({
  servico,
  cadastroHabilitado,
  children,
  caminhoInicial = window.location.pathname,
}: Props) {
  const [acesso, setAcesso] = useState<Acesso>({ tipo: 'verificando' });
  const token = useRef<string | undefined>(undefined);

  const carregarPerfil = useCallback(async (tokenAtual: string) => {
    setAcesso({ tipo: 'verificando' });
    setAcesso(await consultarMe(tokenAtual));
  }, []);

  useEffect(() => {
    const cancelar = servico.aoMudarToken((novo) => {
      token.current = novo;
      if (novo === undefined) setAcesso({ tipo: 'anonimo' });
    });
    if (caminhoInicial !== CAMINHO_RETORNO) {
      void servico.restaurar().then((recuperado) => {
        if (recuperado === undefined) {
          setAcesso({ tipo: 'anonimo' });
          return;
        }
        token.current = recuperado;
        return carregarPerfil(recuperado);
      });
    }
    return cancelar;
  }, [servico, caminhoInicial, carregarPerfil]);

  // Ações estáveis (não mudam com o acesso): as telas podem usá-las em efeitos.
  const acoes = useMemo<Omit<Sessao, 'acesso'>>(
    () => ({
      cadastroHabilitado,
      entrar: (destino = '/') => servico.entrar(destino),
      criarConta: () => servico.criarConta(),
      async concluirEntrada() {
        const resultado = await servico.concluirEntrada();
        token.current = resultado.token;
        await carregarPerfil(resultado.token);
        return resultado.destino;
      },
      async recarregarPerfil() {
        if (token.current === undefined) {
          setAcesso({ tipo: 'anonimo' });
          return;
        }
        await carregarPerfil(token.current);
      },
      sair: () => servico.sair(),
      obterToken: () => token.current,
    }),
    [cadastroHabilitado, servico, carregarPerfil],
  );
  const sessao = useMemo<Sessao>(() => ({ acesso, ...acoes }), [acesso, acoes]);

  return <ContextoSessao value={sessao}>{children}</ContextoSessao>;
}
