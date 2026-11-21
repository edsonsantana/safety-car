// Página de demonstração dos componentes-base: SOMENTE DESENVOLVIMENTO.
// Registrada só com import.meta.env.DEV; o build confere que não vai para o dist/.
import type { ReactNode } from 'react';
import { Botao } from '../componentes/Botao.tsx';
import { CampoCodigo } from '../componentes/CampoCodigo.tsx';
import { CampoTexto } from '../componentes/CampoTexto.tsx';
import { CartaoAviso } from '../componentes/CartaoAviso.tsx';
import { IndicadorEtapas } from '../componentes/IndicadorEtapas.tsx';
import { SeloStatus } from '../componentes/SeloStatus.tsx';
import { EstadoApi } from './EstadoApi.tsx';
import { Titulo } from './Titulo.tsx';

export default function Componentes() {
  return (
    <>
      <Titulo>Componentes</Titulo>
      <p className="text-sm text-texto-sec">
        Demonstração dos componentes-base (só em desenvolvimento).
      </p>

      <Secao titulo="Estado da API">
        <EstadoApi />
      </Secao>

      <Secao titulo="Botões">
        <div className="flex flex-wrap gap-2">
          <Botao>Principal</Botao>
          <Botao variante="secundario">Secundário</Botao>
          <Botao disabled>Desabilitado</Botao>
        </div>
      </Secao>

      <Secao titulo="Campos">
        <CampoTexto rotulo="Nome completo" dica="Como no documento de identidade" />
        <CampoTexto rotulo="E-mail" type="email" erro="Informe um e-mail válido" />
        <CampoCodigo rotulo="Código do autenticador" dica="6 dígitos do aplicativo" />
        <CampoCodigo rotulo="Código com erro" erro="Código incorreto" defaultValue="123" />
      </Secao>

      <Secao titulo="Indicador de etapas">
        <IndicadorEtapas etapas={['Dados', 'Celular', 'Senha', '2FA']} atual={2} />
      </Secao>

      <Secao titulo="Avisos">
        <CartaoAviso titulo="Informação">Enviamos um código para o seu e-mail.</CartaoAviso>
        <CartaoAviso variante="atencao" titulo="Atenção">
          O documento vence em 15 dias.
        </CartaoAviso>
        <CartaoAviso variante="erro" titulo="Erro">
          Não foi possível enviar. Tente de novo.
        </CartaoAviso>
      </Secao>

      <Secao titulo="Selos de status">
        <div className="flex flex-wrap gap-2">
          <SeloStatus status="aprovado" />
          <SeloStatus status="em_analise" />
          <SeloStatus status="pendente" />
          <SeloStatus status="vencido" />
        </div>
      </Secao>
    </>
  );
}

function Secao({ titulo, children }: { titulo: string; children: ReactNode }) {
  return (
    <section className="flex flex-col gap-3 rounded-xl border border-borda bg-branco p-4">
      <h2 className="text-lg font-bold text-marinho">{titulo}</h2>
      {children}
    </section>
  );
}
