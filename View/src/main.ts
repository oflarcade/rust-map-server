import { createApp } from 'vue';
import { VueQueryPlugin, QueryClient } from '@tanstack/vue-query';
import PrimeVue from 'primevue/config';
import Aura from '@primeuix/themes/aura';
import ToastService from 'primevue/toastservice';
import ConfirmationService from 'primevue/confirmationservice';
import App from './App.vue';
import router from './router';
import 'maplibre-gl/dist/maplibre-gl.css';
import 'primeicons/primeicons.css';
import './assets/main.css';

const queryClient = new QueryClient({
  defaultOptions: {
    queries: { staleTime: Infinity, retry: 1, refetchOnWindowFocus: false },
  },
});

createApp(App)
  .use(router)
  .use(VueQueryPlugin, { queryClient })
  .use(PrimeVue, {
    theme: {
      preset: Aura,
      options: {
        darkModeSelector: 'html.dark',
        cssLayer: { name: 'primevue', order: 'tailwind-base, primevue, tailwind-utilities' },
      },
    },
  })
  .use(ToastService)
  .use(ConfirmationService)
  .mount('#app');
