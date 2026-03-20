import { defineConfig } from 'vite';
import vue from '@vitejs/plugin-vue';
import tailwindcss from '@tailwindcss/vite';
import { resolve } from 'path';
import { existsSync, createReadStream } from 'fs';

export default defineConfig({
  plugins: [
    vue(),
    tailwindcss(),
    {
      name: 'serve-hdx',
      configureServer(server) {
        server.middlewares.use((req, res, next) => {
          if (req.url?.startsWith('/hdx/') && req.url.endsWith('.json')) {
            const filePath = resolve(__dirname, '..', req.url.slice(1));
            if (existsSync(filePath)) {
              res.setHeader('Content-Type', 'application/json');
              createReadStream(filePath).pipe(res);
              return;
            }
          }
          next();
        });
      },
    },
  ],
  server: {
    port: 4000,
    open: true,
  },
});
