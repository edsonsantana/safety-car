import { render, screen } from '@testing-library/react';
import { expect, test } from 'vitest';
import { App } from './App.tsx';

test('mostra o título do Safety Car', () => {
  render(<App />);
  expect(screen.getByRole('heading', { level: 1, name: 'Safety Car' })).toBeInTheDocument();
});
