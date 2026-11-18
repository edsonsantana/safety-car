// Variáveis VITE_* vão para o código do navegador: nunca colocar segredo nelas.
interface ImportMetaEnv {
  readonly VITE_API_BASE?: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}
