import { render, screen } from '@testing-library/react';
import { expect, test } from 'vitest';
import { App } from './App.tsx';

test('a aplicação abre na página inicial', () => {
  render(<App />);
  expect(screen.getByRole('heading', { level: 1, name: 'Início' })).toBeInTheDocument();
});
