// O vitest-axe só declara o matcher para a API antiga do Vitest (namespace Vi).
import 'vitest';
import type { AxeMatchers } from 'vitest-axe/matchers';

declare module 'vitest' {
  // A mesclagem de declarações exige os mesmos parâmetros de tipo da interface original.
  // eslint-disable-next-line @typescript-eslint/no-empty-object-type, @typescript-eslint/no-unused-vars, @typescript-eslint/no-explicit-any
  interface Assertion<T = any> extends AxeMatchers {}
}
