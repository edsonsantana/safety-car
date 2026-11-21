import { Link } from 'react-router';
import { useSessao } from '../autenticacao/contexto.ts';
import { Botao } from '../componentes/Botao.tsx';
import { Titulo } from './Titulo.tsx';

// Rotas ainda vazias: só o título. Formulários e lógica entram nas próximas fases.

export function Cadastro() {
  return <Titulo>Cadastro</Titulo>;
}

export function Verificacao() {
  return <Titulo>Verificação</Titulo>;
}

export function InicioTomador() {
  return (
    <>
      <Titulo>Início do tomador</Titulo>
      <BotaoSair />
    </>
  );
}

export function InicioParceiro() {
  return (
    <>
      <Titulo>Início do parceiro</Titulo>
      <BotaoSair />
    </>
  );
}

export function Central() {
  return (
    <>
      <Titulo>Painel da Central</Titulo>
      <BotaoSair />
    </>
  );
}

/** Encerra a sessão local e no Keycloak. */
function BotaoSair() {
  const { sair } = useSessao();
  return (
    <Botao
      variante="secundario"
      className="self-start"
      onClick={() => {
        void sair();
      }}
    >
      Sair
    </Botao>
  );
}

export function NaoEncontrada() {
  return (
    <>
      <Titulo>Página não encontrada</Titulo>
      <p className="text-texto-sec">O endereço digitado não existe.</p>
      <Link to="/" className="font-semibold text-link underline">
        Voltar para o início
      </Link>
    </>
  );
}
