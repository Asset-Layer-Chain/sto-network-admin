import { defineConfig } from 'vite';

const allowedHosts = ['sto-network-admin.stodev.xyz'];

export default defineConfig({
  base: '/',
  server: {
    host: '0.0.0.0',
    port: 3000,
    strictPort: true,
    allowedHosts,
  },
  preview: {
    host: '0.0.0.0',
    port: 3000,
    strictPort: true,
    allowedHosts,
  },
});
