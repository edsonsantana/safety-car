import { useEffect, useRef, useState } from 'react';
import { useNavigate } from 'react-router';
import { useSessao } from '../autenticacao/contexto.ts';
import { TelaEntrando } from './TelaEntrando.tsx';

/**
 * Retorno do Keycloak (/entrando): troca o código pelo token (PKCE), carrega o perfil
 * pelo GET /me e segue para o destino guardado na ida.
 */
export function Entrando() {
  const { concluirEntrada, acesso, entrar } = useSessao();
  const navegar = useNavigate();
  const [destino, setDestino] = useState<string>();
  const [falhou, setFalhou] = useState(false);
  const iniciado = useRef(false);

  useEffect(() => {
    if (iniciado.current) return;
    iniciado.current = true;
    concluirEntrada().then(setDestino, () => {
      setFalhou(true);
    });
  }, [concluirEntrada]);

  const pronto =
    destino !== undefined && acesso.tipo !== 'verificando' && acesso.tipo !== 'indisponivel';
  useEffect(() => {
    if (pronto) void navegar(destino, { replace: true });
  }, [pronto, destino, navegar]);

  const erro = falhou || (destino !== undefined && acesso.tipo === 'indisponivel');
  return (
    <TelaEntrando
      erro={erro}
      aoTentarDeNovo={() => {
        void entrar(destino ?? '/');
      }}
    />
  );
}
