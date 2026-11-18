import { Link } from 'react-router';
import { Titulo } from './Titulo.tsx';

// Rotas ainda vazias: só o título. Formulários e lógica entram nas próximas fases.

export function Cadastro() {
  return <Titulo>Cadastro</Titulo>;
}

export function Entrar() {
  return <Titulo>Entrar</Titulo>;
}

export function Verificacao() {
  return <Titulo>Verificação</Titulo>;
}

export function Central() {
  return <Titulo>Painel da Central</Titulo>;
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
